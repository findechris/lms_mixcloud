package Plugins::MixCloud::Plugin;

# Plugin to stream audio from Mixcloud
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Christian Mueller,
# See file LICENSE for full license details

use strict;
use utf8;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use LWP::Simple;
use LWP::UserAgent;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Date::Parse;

use Data::Dumper;

use Plugins::MixCloud::ProtocolHandler;

my $log;
my $compat;
my $CLIENT_ID = "Js32JMBmKGRg4zjHrY";
my $CLIENT_SECRET = "E3uDXKnsMdWjxJMRtkY3e52JZfUAGnwM";
my $token = "";

my %METADATA_CACHE= {};


BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.mixcloud',
		'defaultLevel' => 'DEBUG',
		'description'  => string('PLUGIN_MIXCLOUD'),
	});   

	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

my $prefs = preferences('plugin.mixcloud');

$prefs->init({ apiKey => "", playmethod => "stream" });

sub getToken {
	my ($callback) = shift;
	if ($prefs->get('apiKey')) {
		my $tokenurl = "https://www.mixcloud.com/oauth/access_token?client_id=".$CLIENT_ID."&redirect_uri=http://findechris.github.io/lms_mixcloud/app.html&client_secret=".$CLIENT_SECRET."&code=".$prefs->get('apiKey');
		$log->info("gettokenurl:".$tokenurl);
		Slim::Networking::SimpleAsyncHTTP->new(			
				sub {
					my $http = shift;				
					my $json = eval { from_json($http->content) };
					if ($json->{"access_token"}) {
						$token = $json->{"access_token"};
						$log->info("token:".$token);
					}				
					$callback->({token=>$token});	
				},			
				sub {
					$log->warn("error: $_[1]");
					$callback->({});
				},			
		)->get($tokenurl);
	}else{
		$callback->({});	
	}
}

sub _makeMetadata {
	my ($json) = shift;

	my $icon = "";
	if (defined $json->{'pictures'}->{'medium'}) {
		$icon = $json->{'pictures'}->{'medium'};
		#$icon =~ s/-large/-t500x500/g;
	}
	#my ($ss,$mm,$hh,$day,$month,$year,$zone,$help) = strptime($json->{'created_time'});
	my $dminutes = int(int($json->{'audio_length'})/60);
	my $dhours = int($dminutes/60);
	my $dminutesrest = int($dminutes-$dhours*60);
	my $DATA = {
		duration => $dhours."h".$dminutesrest."m",
		name => ($json->{'created_time'}?substr($json->{'created_time'},0,10)." : ":"").$json->{'name'},
		title => $json->{'name'},
		#label => substr($json->{'created_time'},0,10),
		artists => $json->{'user'}->{'username'},
		artist => $json->{'user'}->{'username'},
		album => $json->{'user'}->{'name'},
		play => "mixcloud:/" . $json->{'key'},
		bitrate => '320/70',
		url => \&_fetchMeta,
		passthrough => [ { key => $json->{'key'}} ],
		#type => 'audio',
		#line1 => $json->{'name'},
		#line2 => $json->{'name'},
		icon => $icon,
		image => $icon,
		cover => $icon,
	};

	return $DATA;
}

sub _fetchMeta {
	my ($client, $callback, $args, $passDict) = @_;
	
	my $fetchURL = "http://api.mixcloud.com" . $passDict->{"key"} ;
	$log->debug("fetching meta for $fetchURL");
	Slim::Networking::SimpleAsyncHTTP->new(
		
		sub {
			my $track = eval { from_json($_[0]->content) };			
			if ($@) {
				$log->warn($@);
			}				
			$log->debug("got meta for $fetchURL");
			my $meta = _makeMetadata($track);
			#$meta->{"items"} = [_makeMetadata($track)];
			$callback->($meta);
		}, 
		
		sub {
			$log->warn("error fetching track data: $_[1]");
		},
		
		{ timeout => 35 },
		
	)->get($fetchURL);
}

sub _parseTracks {
	my ($json, $menu) = @_;
	my $data = $json->{'data'}; 
	for my $entry (@$data) {
		push @$menu, _makeMetadata($entry);
	}
}

sub tracksHandler {
	my ($client, $callback, $args, $passDict) = @_;

	my $index    = ($args->{'index'} || 0); # ie, offset
	my $quantity = $args->{'quantity'} || 200;
	my $searchType = $passDict->{'type'};

	my $parser = $passDict->{'parser'} || \&_parseTracks;
	my $params = $passDict->{'params'} || '';

	$log->warn('search type: ' . $searchType);
	$log->warn("index: " . $index);
	$log->warn("quantity: " . $quantity);
	
	my $menu = [];
	
	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;
	
	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??

	$fetch = sub {
		# in case we've already fetched some of this page, keep going
		my $i = $index + scalar @$menu;
		$log->warn("i: " . $i);
		my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
		$log->warn("max: " . $max);
		my $method = "http";
		my $uid = $passDict->{'uid'} || '';
		my $resource = "";
		if ($searchType eq 'hot') {
			$resource = "popular/hot";
		}
		if ($searchType eq 'popular') {
			$resource = "popular";
		}
		if ($searchType eq 'new') {
			$resource = "new";
		}
		if ($searchType eq 'categories') {
			if ($params eq "") {
				$resource = "categories";
			}else{
				$resource = $params;
				$params = "";
			}			
		}
		if ($searchType eq 'search') {
			$resource = "search";
			$params = "q=".$args->{'search'}."&type=cloudcast"; 
		}
		if ($searchType eq 'tags') {
			if ($params eq "") {
				$resource = "search";
				$params = "q=".$args->{'search'}."&type=tag";
			}else{
				$resource = $params;
				$params = "";
			}			 
		}

		if ($token ne "") {
			if ($searchType eq 'following') {
				$resource = "me/following";
			}
			if ($searchType eq 'favorites') {
				$resource = "me/favorites";
			}
			if ($searchType eq 'cloudcasts') {
				$resource = "me/cloudcasts";
			}
			$method = "https";
			$params .= "&access_token=" . $token;
			
			
		}
		
		my $queryUrl = "$method://api.mixcloud.com/$resource?offset=$i&limit=$quantity&" . $params;
		#$queryUrl= "http://192.168.56.1/json/cloudcasts.json";
		$log->warn("fetching: $queryUrl");
		
		Slim::Networking::SimpleAsyncHTTP->new(
			
			sub {
				my $http = shift;				
				my $json = eval { from_json($http->content) };
				
				$parser->($json, $menu); 
	
				# max offset = 8000, max index = 200 sez 
				my $total = 8000 + $quantity;
				if (exists $passDict->{'total'}) {
					$total = $passDict->{'total'}
				}
				
				$log->info("this page: " . scalar @$menu . " total: $total");

				# TODO: check this logic makes sense
				if (scalar @$menu < $quantity) {
					$total = $index + @$menu;
					$log->debug("short page, truncate total to $total");
				}
		
				$callback->({
					items  => $menu,
					offset => $index,
					total  => $total,
				});
			},
			
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
			
		)->get($queryUrl);
	};
		
	$fetch->();
}

sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
	
	$url =~ s/ com/.com/;
	$url =~ s/www /www./;
	my ($trackhome) = $url =~ m{^http://www.mixcloud.com/(.*)$};
	my $queryUrl = "http://api.mixcloud.com/" . $trackhome ;

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

				$callback->({
					items => [ _makeMetadata($json) ]
				});
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
		)->get($queryUrl);
	};
		
	$fetch->();
}

sub _parseCategories {
	my ($json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $format = $entry->{'format'};
		my $slug = $entry->{'slug'};
		my $url = $entry->{'url'};
		my $key = substr($entry->{'key'},1)."cloudcasts/";

		push @$menu, {
			name => $name,
			type => 'link',
			url => \&tracksHandler,
			passthrough => [ { type => 'categories', params => $key} ]
		};
	}
}

sub _parseTags {
	my ($json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $format = $entry->{'format'};
		my $slug = $entry->{'slug'};
		my $url = $entry->{'url'};
		my $key = substr($entry->{'key'},1);
		push @$menu, {
			name => $name,
			type => 'link',
			url => \&_tagHandler,
			passthrough => [ { params => $key} ]
		};
	}
}

sub _tagHandler {
	my ($client, $callback, $args, $passDict) = @_;
	my $params = $passDict->{'params'} || '';
	my $callbacks = [
		{ name => string('PLUGIN_MIXCLOUD_NEW'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags' ,params=>$params.'new/' } ], },

		{ name => string('PLUGIN_MIXCLOUD_POPULAR'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags'  ,params=>$params.'popular/'} ], },
		
		{ name => string('PLUGIN_MIXCLOUD_HOT'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags' ,params=>$params.'hot/' } ], },

	];
	$callback->($callbacks);
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'mixcloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

	if (!$::noweb) {
		require Plugins::MixCloud::Settings;
		Plugins::MixCloud::Settings->new;
	}

	#Slim::Formats::RemoteMetadata->registerProvider(
	#	match => qr/mixcloud\.com/,
	#	func => \&metadata_provider,
	#);*/

	Slim::Player::ProtocolHandlers->registerHandler(
		mixcloud => 'Plugins::MixCloud::ProtocolHandler'
	);
}

sub shutdownPlugin {
	my $class = shift;
}

sub getDisplayName { 'PLUGIN_MIXCLOUD' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
	my ($client, $callback, $args) = @_;

	my $callbacks = [
		{ name => string('PLUGIN_MIXCLOUD_HOT'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'hot' } ], },

		{ name => string('PLUGIN_MIXCLOUD_NEW'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'new' } ], },
		
		{ name => string('PLUGIN_MIXCLOUD_POPULAR'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'popular' } ], },
		
		{ name => string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories',parser => \&_parseCategories } ], },

		{ name => string('PLUGIN_MIXCLOUD_SEARCH'), type => 'search',   
			url  => \&tracksHandler, passthrough => [ { type => 'search' } ], },

		{ name => string('PLUGIN_MIXCLOUD_TAGS'), type => 'search',   
			url  => \&tracksHandler, passthrough => [ { type => 'tags',parser => \&_parseTags } ], },
	];

	

	
	getToken(
			 sub{
				if ($token ne '') {
					push(@$callbacks, 
						{ name => string('PLUGIN_MIXCLOUD_FOLLOWING'), type => 'link',
							url  => \&tracksHandler, passthrough => [ { type => 'following' } ] }
					);
					push(@$callbacks, 
						{ name => string('PLUGIN_MIXCLOUD_FAVORITES'), type => 'link',
							url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
					);
					push(@$callbacks, 
						{ name => string('PLUGIN_MIXCLOUD_CLOUDCASTS'), type => 'link',
							url  => \&tracksHandler, passthrough => [ { type => 'cloudcasts'} ] }
					);
				}
				push(@$callbacks, 
					{ name => string('PLUGIN_MIXCLOUD_URL'), type => 'search', url  => \&urlHandler, }
				);
				$callback->($callbacks);			
			}
	)
	
}

1;
