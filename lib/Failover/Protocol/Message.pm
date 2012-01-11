package Failover::Protocol::Message;
use strict;
use warnings;
use Failover::Protocol::ID;

use JSON::XS;
use Log::Fu;

my %ACC_PROTOMAP;
BEGIN {
    %ACC_PROTOMAP = (
        IDENT => 'ident',
        PROPOSE => 'proposal',
        MY_STATUS => 'status',
        OBJECTION => 'objection',
        REQUEST=> 'request'
    );
}

use Class::XSAccessor {
    constructor => 'new',
    accessors => [values %ACC_PROTOMAP]
};

sub decode_hash {
    my ($cls,$hash) = @_;
    my $o = Failover::Protocol::Message->new();
    while (my ($field,$acc) = each %ACC_PROTOMAP) {
        $o->$acc($hash->{$field});
    }
    
    if($o->ident) {
        $o->ident(Failover::Protocol::ID->decode_str($o->ident));
    }
    
    return $o;
}

sub decode_blob {
    my ($cls,$parser,$blob) = @_;
    #log_info($blob);
    $parser ||= JSON::XS->new();
    return ($parser, $parser->incr_parse($blob));
}

sub encode {
    my $self = shift;
    my $response = {};
    while ( my ($field,$acc) = each %ACC_PROTOMAP) {
        if(defined $self->$acc) {
            $response->{$field} = $self->$acc;
        }
    }
    encode_json($response);
}
1;