package Failover::Client;
use strict;
use warnings;
use Socket;

use Class::XSAccessor {
    constructor => 'new',
    accessors => [qw(parser)]
};

use Failover::Peer;
use Failover::Protocol::Message;
use IO::Socket::INET;
use Log::Fu { level => "debug" };
use Data::Dumper;

sub get_master {
    my ($self,@peers) = @_;
    @peers = @Failover::Peer::PeerList if!@peers;
    foreach (@peers) {
        if(!ref($_) || !$_->isa('Failover::Peer')) {
            $_ = Failover::Peer->peer_by_addr($_);
        }
    }
    
    my $request = Failover::Protocol::Message->new(request => '...')->encode();
    my ($parser,$message);
    my $master;
    
    PEER_ITER:
    foreach my $peer (@peers) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => $peer->ipaddr,
            Timeout => 5
        );
        if(!$sock) {
            log_warnf("%s: $!", $peer->ipaddr);
            next;
        }
        log_debugf("Connected to %s", $peer->ipaddr);
        $sock->send($request, 0);
        #my $buf = "";
        #$sock->recv($buf = "", 8192, 0);
        #log_info($buf);
        while(defined ($sock->recv(my $buf = "", 8192, 0) ) ) {
            if(!$buf) {
                last;
            }
            ($parser,$message) = Failover::Protocol::Message->decode_blob(
                $parser, $buf);
            #if($message) {
            #    print Dumper($message);
            #}
            if($message && $message->{INFO})  {
                foreach my $h (values %{$message->{INFO}}) {
                    if($h->{MY_STATUS} == HA_STATE_ACTIVE) {
                        $master = $h->{ADDR};
                        last PEER_ITER;
                    }
                }
            } else {
                log_warn("Can't get message from $buf");
            }
        }
    }
    if($master) {
        log_info("Have master at $master");
    } else {
        if($message) {
            print Dumper($message);
        }
        log_err("Couldn't find master");
    }
    return $master;
}

if(!caller) {
    __PACKAGE__->new->get_master(@ARGV);
}