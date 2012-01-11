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
    FOPROTO_PRI_DEFAULT     => 4096,
}, -export => 1;


sub proto_ident {
    my $self = shift;
    return {
        IDENT => $self->id->encode_str,
        %{$self->proto_my_status},
    };
}

sub proto_highest_id {
    
}

sub proto_propose {
    my $self = shift;
    return {
        IDENT   => $self->id->encode_str,
        PROPOSE => "blah"
    };
}

sub proto_propose_objection {
    my $self = shift;
    return {
        IDENT => $self->id->encode_str,
        OBJECTION => 'blah',
        MY_STATUS => $self->state
    };
}

sub proto_my_status {
    my $self = shift;
    return {
        MY_STATUS => $self->state,
        IDENT     => $self->id->encode_str,
    };
}

sub proto_respond_to_client {
    my $self = shift;
    my $response = {};
    my $info = {};
    foreach my $peer ($self,@{$self->neighbors}) {
        my $prid_str = $peer->id->encode_str();
        $info->{$prid_str}->{IDENT} = $prid_str;
        $info->{$prid_str}->{ADDR} = $peer->ipaddr;
        $info->{$prid_str}->{MY_STATUS} = $peer->state;
    }
    $response->{INFO} = $info;
    return $response;
}

use Data::Dumper;

sub parse {
    my ($self,$input) = @_;
    #log_info(Dumper($input));
    Failover::Protocol::Message->decode_hash($input);
}
1;