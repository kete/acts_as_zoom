#!/usr/bin/perl

use ZOOM;

my $host = shift;
my $port = shift;
my $recordId = shift;
my $record = shift;
my $action = shift;
my $database = shift;
my $username = shift;
my $password = shift;

print "host ".$host;
print "port ".$port;
print "recordId ".$recordId;
print "record ".$record;
print "action ".$action;
print "database ".$database;
print "username ".$username;
print "password ".$password;

eval {
    $conn = new ZOOM::Connection($host, $port, user => $username, password => $password );
    $conn->option(preferredRecordSyntax => "xml");

    if ($database) {
	$conn->option(databaseName => $database);
    }
    
    $p = $conn->package();
    $p->option(action => $action);
    $p->option(recordIdOpaque => $recordId);
    $p->option(record => $record);
    $p->send("update");
    $p->send("commit");
    $p->destroy();

};
if ($@ && $@->isa("ZOOM::Exception")) {
    print "Oops!  ", $@->message(), "\n";
    print $@->code();
}
