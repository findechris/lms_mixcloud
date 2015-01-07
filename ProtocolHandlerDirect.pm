package Plugins::MixCloud::ProtocolHandlerDirect;

use strict;

use base qw(Slim::Formats::RemoteStream);

use IO::Socket qw(:crlf);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $id = 0; # unique id for track being played

my $prefetch; # timer for prefetch of next track

my $prefs = preferences('plugin.mixcloud');
my $log   = logger('plugin.mixcloud');

sub bufferThreshold { 80 }

sub requestString {
	my $self   = shift;
	#my $client = shift;
	#my $url    = shift;
	#my $post   = shift;
	#my $seekdata = shift;

	Plugins::MixCloud::ProtocolHandler->requestString(@_);
}

1;
