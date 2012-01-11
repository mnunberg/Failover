package Failover::Bootstrap;
use strict;
use warnings;
use Dir::Self;
use File::Slurp qw(read_file);
use Failover::Peer;
use Failover::Protocol;
use Failover::Protocol::ID;
use Log::Fu { level => "debug" };

my @configs = read_file(__DIR__ . "/peers.conf");
foreach my $line (@configs) {
    my @confpairs = split(/\s/, $line);
    my %opthash = map { split(/=/, $_) } @confpairs;
    if(!%opthash) {
        next;
    }
    
    my $id = delete $opthash{id} or die "Missing ID in config $line";
    my $pri = delete $opthash{pri};
    $pri = FOPROTO_PRI_DEFAULT unless defined $pri;
    my $ipaddr = delete $opthash{ipaddr};
    die("Must have IP") unless defined $ipaddr;
    log_infof("Found IP=%s PRI=%d", $ipaddr, $pri);
    $id = Failover::Protocol::ID->new_with_uuid($id);
    my $peer = Failover::Peer->new(ipaddr => $ipaddr, id => $id, pri => $pri);
    push @Failover::Peer::PendingNodes, $peer;
}

1;