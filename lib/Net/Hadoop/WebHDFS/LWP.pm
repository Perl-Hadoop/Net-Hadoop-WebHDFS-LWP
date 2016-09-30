package Net::Hadoop::WebHDFS::LWP;

use strict;
use warnings;
use parent 'Net::Hadoop::WebHDFS';

# VERSION

use LWP::UserAgent;
use Carp;
use Ref::Util    qw( is_arrayref );
use Scalar::Util qw( openhandle );
use HTTP::Request::StreamingUpload;

sub new {
    my $class   = shift;
    my %options = @_;
    my $debug   = $options{debug} || 0;
    require Data::Dumper if $debug;

    my $self = $class->SUPER::new(@_);

    # we don't need Furl
    delete $self->{furl};
    $self->{debug} = $debug;

    my %ua_opts;
    for my $passthru_opt (qw/ env_proxy proxy no_proxy /) {
        $ua_opts{$passthru_opt} = $options{$passthru_opt}
            if ( exists $options{$passthru_opt} );
    }

    $self->{ua} = LWP::UserAgent->new( %ua_opts );
    $self->{ua}->agent("Net::Hadoop::WebHDFS::LWP " . $class->VERSION );
    $self->{useragent} = $self->{ua}->agent;

    # default timeout is a bit short, raise it
    $self->{timeout} = $options{timeout} || 30;
    $self->{ua}->timeout( $self->{timeout} );

    # For filehandle upload support
    $self->{chunksize} = $options{chunksize} || 4096;

    return $self;
}

# Code below copied and modified for LWP from Net::Hadoop::WebHDFS
#
sub request {
    my ( $self, $host, $port, $method, $path, $op, $params, $payload, $header ) = @_;

    my $request_path = $op ? $self->build_path( $path, $op, %$params ) : $path;

    # Note: ugly things done with URI, which is already used in the parent
    # module. So we re-parse the path produced there. yuk.
    my $uri = URI->new( $request_path, 'http' );

    $uri->host($host);
    $uri->port($port);
    $uri->scheme('http'); # no ssl for webhdfs? check the docs

    print "URI : $uri\n" if $self->{debug};

    my $req;

    if ( $payload && openhandle($payload) ) {
        $req = HTTP::Request::StreamingUpload->new(
            $method => $uri,
            fh      => $payload,
            headers    => HTTP::Headers->new( 'Content-Length' => -s $payload, ),
            chunk_size => $self->{chunksize},
        );
    }
    elsif ( ref $payload ) {
        croak __PACKAGE__ . " does not accept refs as content, only scalars and FH";
    }
    else {
        $req = HTTP::Request->new( $method => $uri );
        $req->content($payload);
    }

    if ( is_arrayref( $header ) ) {
        while ( my ( $h_field, $h_value ) = splice( @{ $header }, 0, 2 ) ) {
            $req->header( $h_field => $h_value );
        }
    }

    my $real_res = $self->{ua}->request($req);

    my $res = { code => $real_res->code, body => $real_res->decoded_content };
    my $code = $real_res->code;
    print "HTTP code : $code\n" if $self->{debug};

    my $headers = $real_res->headers;
    print "Headers: " . Data::Dumper::Dumper $headers if $self->{debug};
    for my $h_key ( keys %{ $headers || {} } ) {
        my $h_value = $headers->{$h_key};

        if    ( $h_key =~ m!^location$!i )     { $res->{location}     = $h_value; }
        elsif ( $h_key =~ m!^content-type$!i ) { $res->{content_type} = $h_value; }
    }

    return $res if $res->{code} >= 200 and $res->{code} <= 299;
    return $res if $res->{code} >= 300 and $res->{code} <= 399;

    my $errmsg = $res->{body} || 'Response body is empty...';
    $errmsg =~ s/\n//g;

    if ( $code == 400 ) { croak "ClientError: $errmsg"; }

    # this error happens for secure clusters when using Net::Hadoop::WebHDFS,
    # but LWP::Authen::Negotiate takes care of it transparently in this module.
    # we still may get this error on a secure cluster, when the credentials
    # cache hasn't been initialized
    elsif ( $code == 401 ) {
        my $extramsg = ( $headers->{'www-authenticate'} || '' ) eq 'Negotiate'
            ? eval { require "LWP::Authen::Negotiate" }
                ? ' (Did you forget to run kinit?)'
                : ' (LWP::Authen::Negotiate doesn\'t seem available)'
            : '';
        croak "SecurityError$extramsg: $errmsg";
    }

    elsif ( $code == 403 ) {
        if ( $errmsg =~ /org\.apache\.hadoop\.ipc\.StandbyException/ ) {
            if ( $self->{httpfs_mode} || not defined( $self->{standby_host} ) ) {

                # failover is disabled
            }
            elsif ( $self->{retrying} ) {

                # more failover is prohibited
                $self->{retrying} = 0;
            }
            else {
                $self->{under_failover} = not $self->{under_failover};
                $self->{retrying}       = 1;
                my ( $next_host, $next_port ) = $self->connect_to();
                my $val = $self->request( $next_host, $next_port, $method, $path, $op, $params,
                    $payload, $header );
                $self->{retrying} = 0;
                return $val;
            }
        }
        croak "IOError: $errmsg";
    }
    elsif ( $code == 404 ) { croak "FileNotFoundError: $errmsg"; }
    elsif ( $code == 500 ) { croak "ServerError: $errmsg"; }

    croak "RequestFailedError, code:$code, message:$errmsg";
}

1;

#ABSTRACT: Client library for Hadoop WebHDFS and HttpFs, with Kerberos support

=head1 SYNOPSIS

    use Net::Hadoop::WebHDFS::LWP;

    my $client = Net::Hadoop::WebHDFS::LWP->new(
        host        => 'webhdfs.local',
        port        => 14000,
        username    => 'jdoe',
        httpfs_mode => 1,
    );
    $client->create(
        '/foo/bar', # path
        "...",      # content
        permission => '644',
        overwrite => 'true'
    ) or die "Could not write to HDFS";

=head1 DESCRIPTION

This module is a quick and dirty hack to add Kerberos support to Satoshi
Tagomori's module L<Net::Hadoop::WebHDFS>, to access Hadoop secure clusters. It
simply subclasses the original module, replacing L<Furl> with L<LWP>, which
will transparently use L<LWP::Authen::Negotiate> when needed. So the real
documentation is contained in L<Net::Hadoop::WebHDFS>.

=head1 ACKNOWLEDGEMENTS

As mentioned above, the real work was done by Satoshi Tagomori

Thanks to my employer Booking.com to allow me to release this module for public use

