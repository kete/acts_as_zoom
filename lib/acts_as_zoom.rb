# TODO: put in license and copyright

require 'active_record'
require 'rexml/document'
require 'yaml'
# this is how we talk to a Z39.50 server
# like zebra or voyager
require 'zoom'
# our model for storing Z39.50 server connection information
require 'zoom_db'

module ZoomMixin
  module Acts #:nodoc:
    module ARZoom #:nodoc:

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        include ZoomMixin

        def get_field_value(field)
          fields_for_zoom << field
          define_method("#{field}_for_zoom".to_sym) do
            begin
              value = self[field] || self.instance_variable_get("@#{field.to_s}".to_sym) || self.method(field).call
            rescue
              value = ''
              logger.debug "There was a problem getting the value for the field '#{field}': #{$!}"
            end
          end
        end

        def acts_as_zoom(options={})
          configuration = {
            :fields => nil,
            :raw => false,
            :save_to_public_zoom => nil,
            :save_to_private_zoom => nil
          }

          # we need at least save_to_public_zoom to have a hash of :database and :host
          configuration.update(options) if options.is_a?(Hash)

          class_eval <<-CLE
              include ZoomMixin::Acts::ARZoom::InstanceMethods

              after_save    :zoom_save
              after_destroy :zoom_destroy

              cattr_accessor :fields_for_zoom
              cattr_accessor :configuration

              @@fields_for_zoom = Array.new
              @@configuration = configuration

              if configuration[:fields].respond_to?(:each)
                configuration[:fields].each do |field|
                  get_field_value(field)
                end
              else
                @@fields_for_zoom = nil
              end
            CLE
        end

        # we want to stay closer to process_query directly
        # find_by_zoom is may be worth keeping, but probably not

        # adjust to return zoom result set which then can have the following done to it:
        # result_set[key] - get the record corresponding to that key
        # each_record{|record| block_code} pretty obvious, probably mostly useful for small result sets
        # length or size - number of records in set, obviously useful for pagination, etc.
        # see http://ruby-zoom.rubyforge.org/xhtml/ch04.html
        # the problem here is that is we have to accomdate results that may not match our class
        # or be in our app
        def find_by_zoom(options={})
          # expects :query or :pqf_query
          # and :zoom_db
          rset = process_query(options)
          if rset.size > 0
            ids = Array.new
            re = Regexp.new("([^:]+)$")
            rset.each_record do |record|
              temp_hash = Hash.from_xml(record.xml)
              record_id = temp_hash[:localControlNumber].match re
              record_id = record_id.to_s
              ids << record_id.to_i
            end
            conditions = [ "#{self.table_name}.id in (?)", ids ]
            result = self.find(:all, :conditions => conditions)
          else
            return ""
          end
        end

        # Rebuilds the Zoom index
        def rebuild_zoom_index
          self.find(:all).each {|content| content.zoom_save}
          logger.debug self.count>0 ? "Index for #{self.name} has been rebuilt" : "Nothing to index for #{self.name}"
        end

        def process_query(args = {})
          query = args[:query]
          zoom_db = args[:zoom_db]
          pqf_query = args[:pqf_query]

          options = {}

          hostname, port = zoom_db.host, zoom_db.port.to_i
          options['user'] = zoom_db.zoom_user
          options['password'] = zoom_db.zoom_password

          conn = ZOOM::Connection.new(options).connect(hostname, port)
          conn.database_name = zoom_db.database_name
          # we are always using xml at this point
          conn.preferred_record_syntax = 'XML'

          # to search "any" attribute
          # don't specify an attr
          # assumes thatt your z39.50 database
          # has "all" mapped to "any"
          # attr = case type
          #        when SEARCH_BY_ISBN     then [7]
          #        when SEARCH_BY_TITLE    then [4]
          #        when SEARCH_BY_AUTHORS  then [1, 1003]
          #        when SEARCH_BY_KEYWORD  then [1016]
          #        end
          # make case insensitive
          # make fuzzy searches
          # @attr 5=103 is "fuzzy", but not really, and breaks if we add other attributes
          # so we are going to use @attr 5=3, which allows truncation from both the left and right side
          # of the search term
          # i.e. where the record includes "test", find @attr 5=3 est or find @attr 5=3 tes would both match
          # strangely this also turns on case insensitivity

          # query = simply search terms i.e. a list of words to look for
          # may include phrases noted by double quotes or single quotes
          # whack an @and (more terms narrows search results)
          # we need this for limiting our results to a type based on zoom_id's class name
          # this assumes your record has an attribute that maps to bib1.att's attr 12
          pqf = ""
          if pqf_query
            # this is free form, all bets are off
            # probably used by federated searches
            pqf = pqf_query.to_s
          else
            search_terms = split_to_search_terms(query)
            # the and operator along with @attr 1=12 self.class.name
            # limits our results to only the type we are dealing with
            pqf = "@and @attr 1=12 #{self.class.name} "
            # add sort by dynamic ranking (relevance to term)
            pqf += "@attr 2=102 "
            # add matching of partial words
            # which also adds case insensitivity for some reason
            pqf += "@attr 5=3 "
            # now add the words and phrases we are searching for
            pqf += search_terms.join(" ")
          end

          puts "pqf is #{pqf}, syntax XML" if $Z3950_DEBUG
          conn.search(pqf)
        end

        def split_to_search_terms(query)
          # based on http://jystewart.net/process/archives/2006/10/splitting-search-terms
          # return an array of terms either words or phrases
          # Find all phrases enclosed in quotes and pull
          # them into a flat array of phrases
          double_phrases = query.scan(/"(.*?)"/).flatten
          single_phrases = query.scan(/'(.*?)'/).flatten

          # Remove those phrases from the original string
          left_over = query.gsub(/"(.*?)"/, "").squeeze(" ").strip
          left_over = left_over.gsub(/'(.*?)'/, "").squeeze(" ").strip

          # Break up the remaining keywords on whitespace
          keywords = left_over.split(/ /)

          keywords + double_phrases + single_phrases
        end
      end

      module InstanceMethods
        include ZoomMixin

        def zoom_id
          # assumes that the Z39.50 on the other end uses save format for recordId
          # as we we have
          # seems like a safe assumption, seeing as we have write perm on the Z39.50 server
          # you may have to adjust for your needs
          # this form of recordId also assumes that Class:id is unique in the Z39.50 server
          # thus limiting the Z39.50 database to one rails app
          # it's pretty trivial to set up an additional Z39.50 db, so this seems reasonable
          "#{self.class.name}:#{self.id}"
        end

        def zoom_choose_zoom_db
          begin
            public_zoom = configuration[:save_to_public_zoom]
            private_zoom = configuration[:save_to_private_zoom]

            # what is the correct server?
            zoom_db_data = Hash.new

            # public by default
            if public_zoom
              zoom_db_data = { :db_host => public_zoom[0], :db_name => public_zoom[1] }
            end

            # even if we have a private zoom db, the object might be public
            if private_zoom
              # check whether this is a private object
              if self.private?
                zoom_db_data = { :db_host => private_zoom[0], :db_name => private_zoom[1] }
              end
            end

            zoom_db = ZoomDb.find_by_host_and_database_name(zoom_db_data[:db_host],zoom_db_data[:db_name])

            return zoom_db

          rescue
            logger.error "Couldn't get any zoom_db configuration parameters."
            false
          end
        end

        def zoom_prepare_record
          zoom_record = ''
          # raw?
          if configuration[:raw]
            # assumes only a single field, as noted in the README
            fields_for_zoom.first do |field|
              value = self.send("#{field}_for_zoom")
              zoom_record = value.to_s
            end
          else
            zoom_record = to_zoom_record.to_s
          end
        end

        # saves to the appropriate ZoomDb based on configuration
        def zoom_save
          logger.debug "zoom_save: #{self.class.name} : #{self.id}"

          zoom_record = self.zoom_prepare_record

          # get the correct zoom database connection parameters
          zoom_db = self.zoom_choose_zoom_db

          # here's where we actually add/replace the record on the zoom server
          # specialUpdate will insert if no record exists, or replace if one does
          `#{RAILS_ROOT}/vendor/plugins/acts_as_zoom/lib/zoom_ext_services_action.pl \"#{zoom_db.host}\" \"#{zoom_db.port}\" \"#{zoom_id}\" \"#{zoom_record}\" specialUpdate \"#{zoom_db.database_name}\" \"#{zoom_db.zoom_user}\" \"#{zoom_db.zoom_password}\"`.each_line do |l|
            logger.debug "zoom_save: #{self.class.name} : #{self.id} : #{l}"
          end
          true
        end

        def zoom_destroy
          logger.debug "zoom_destroy: #{self.class.name} : #{self.id}"

          # need to pass in whole record as well as zoom_id, even though it's a delete
          zoom_record = self.zoom_prepare_record

          # get the correct zoom database connection parameters
          zoom_db = self.zoom_choose_zoom_db

          # here's where we actually delete the record on the zoom server
          `#{RAILS_ROOT}/vendor/plugins/acts_as_zoom/lib/zoom_ext_services_action.pl \"#{zoom_db.host}\" \"#{zoom_db.port}\" \"#{zoom_id}\" \"#{zoom_record}\" recordDelete \"#{zoom_db.database_name}\" \"#{zoom_db.zoom_user}\" \"#{zoom_db.zoom_password}\"`.each_line do |l|
            logger.debug "zoom_destroy: #{self.class.name} : #{self.id} : #{l}"
          end
          true
        end

        # TODO: check this properly converts records to zoom record
        def to_zoom_record
          logger.debug "to_zoom_record: creating record for class: #{self.class.name}, id: #{self.id}"
          record = REXML::Element.new('record')

          # Zoom id is <classname>:<id> to be unique across all models

          # assumes that you have localControlNumber mapped to bib1's Local-number on your Z39.50
          # server, most likely zebra
          # our inserts, updates, and deletes will break if this isn't set up correctly
          record.add_element field("localControlNumber", zoom_id)

          # iterate through the fields and add them to the document,
          default = ""
          unless fields_for_zoom
            self.attributes.each_pair do |key,value|
              record.add_element field("#{key}", value.to_s) unless key.to_s == "id"
              default << "#{value.to_s} "
            end
          else
            fields_for_zoom.each do |field|
              value = self.send("#{field}_for_zoom")
              record.add_element field("#{field}", value.to_s)
              default << "#{value.to_s} "
            end
          end
          logger.debug record
          return record
        end

        def field(name, value)
          field = REXML::Element.new("#{name}")
          field.add_text(value)
          field
        end

      end
    end
  end
end

# reopen ActiveRecord and include all the above to make
# them available to all our models if they want it
ActiveRecord::Base.class_eval do
  include ZoomMixin::Acts::ARZoom
end
