package Failover::Protocol::ID;
use strict;
use warnings;
use Data::UUID;
use base qw(Exporter);
our @EXPORT;

my $Ug = Data::UUID->new();

use Class::XSAccessor {
    constructor => '_new',
    accessors => [qw(uuid flags)]
};

use Constant::Generate [qw(
    FO_IDf_BOOTSTRAP
    FO_IDf_PROVIDER
    FO_IDf_CONFIRMED
)], -start_at => 1, -type => 'bit', -export => 1;

sub new_bootstrapped {
    my ($cls,$str_uuid) = @_;
    my $o = $cls->new_with_uuid($str_uuid);
    $o->flags($o->flags | FO_IDf_PROVIDER | FO_IDf_BOOTSTRAP);
}

sub new_client {
    my $cls = shift;
    bless my($o), $cls;
    $o->uuid($Ug->create);
    $o->flags(0);
}

sub new_with_uuid {
    my ($cls,$str_uuid) = @_;
    bless my $o = {}, $cls;
    $o->uuid($Ug->from_string($str_uuid));
    $o->flags(FO_IDf_PROVIDER|FO_IDf_CONFIRMED);
    return $o;
}

sub is_confirmed {
    my $self = shift;
    $self->flags & FO_IDf_CONFIRMED;
}

sub encode_str {
    my $self = shift;
    sprintf("%d:%s", $self->flags, $Ug->to_string($self->uuid));
}

sub decode_str {
    my ($cls,$str) = @_;
    my $o = $cls->_new();
    #bless my($o), $cls;
    my ($flag,$str_uuid) = split(/:/, $str);
    $o->uuid($Ug->from_string($str_uuid));
    $o->flags($flag);
    return $o;
}

sub compare {
    my ($self,$other) = @_;
    $Ug->compare($self->uuid, $other->uuid);
}

sub equals {
    my ($self,$other) = @_;
    $Ug->compare($self->uuid, $other->uuid) == 0;
}

sub hash {
    my $self = shift;
    $Ug->to_string($self->uuid);
}