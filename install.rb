src  = IO.readlines(File.dirname(__FILE__)+'/lib/templates/zebra.yml')
dest = File.new(File.dirname(__FILE__)+'/../../../config/zebra.yml','w+')
dest << src
dest.close
