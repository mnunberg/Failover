package Failover::Protocol;
use strict;
use warnings;
use base qw(Exporter);
use Failover::Protocol::Message;
use POE::Filter::JSON::Incr;

our @EXPORT;

sub poe_filter {
    POE::Filter::JSON::Incr->new();
}

use Constant::Generate [qw(UNDEF DOWN ACTIVE STANDBY)],
    -prefix => 'HA_STATE_',
    -start_at => 100,
    -mapname => 'foproto_strstate',
    -export => 1;

use Constant::Generate [qw(
    FOPROTO_PARSE_IDENT
    FOPROTO_PARSE_STATUS
)], -export => 1;
use Constant::Generate {
    FOPROTO_TIMEO_IDENT     => 2,
    FOPROTO_TIMEO_REPORT    => 60,
    FOPROTO_RECONNECT_INTERVAL => 2,
    FOPROTO_PROPOSAL_EXPIRY => 5,
    FOPROTO_ANNOUNCE_INTERVAL => 2,
    FOPROTO_TIMEO_SETTLE    => 10,
    FOPROTO_DYNPEER_MIN     => 1000,
}, -export => 1;


sub proto_ident {
    my $self = shift;
    return {
        IDENT => $self->id,
        %{$self->proto_my_status},
    };
}

sub proto_highest_id {
    
}

sub proto_propose {
    my $self = shift;
    return {
        IDENT   => $self->id,
        PROPOSE => "blah"
    };
}

sub proto_propose_objection {
    my $self = shift;
    return {
        IDENT => $self->id,
        OBJECTION => 'blah',
        MY_STATUS => $self->state
    };
}

sub proto_my_status {
    my $self = shift;
    return {
        MY_STATUS => $self->state,
        IDENT     => $self->id,
    };
}

sub proto_respond_to_client {
    my $self = shift;
    my $response = {};
    my $info = {};
    foreach my $peer ($self,@{$self->neighbors}) {
        $info->{$peer->id}->{IDENT} = $peer->id;
        $info->{$peer->id}->{ADDR} = $peer->ipaddr;
        $info->{$peer->id}->{MY_STATUS} = $peer->state;
    }
    $response->{INFO} = $info;
    return $response;
}

sub parse {
    my ($self,$input) = @_;
    Failover::Protocol::Message->decode_hash($input);
}
1;