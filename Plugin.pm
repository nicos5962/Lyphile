package Plugins::Lyphile::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use IO::Socket::INET;
use File::Spec::Functions ();
use Slim::Utils::Network;
use Slim::Utils::OSDetect;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Pages;

use Plugins::Lyphile::Settings;
use Plugins::Lyphile::VLC::Control;
use Plugins::Lyphile::VLC::ControlLua;
use Plugins::Lyphile::FFmpeg::Control;
use Plugins::Lyphile::MPV::Control;
use Plugins::Lyphile::StreamInfo;
use Plugins::Lyphile::VLC::PlayerSettings;
use Plugins::Lyphile::VLC::PlayerSettingsLua;
use Plugins::Lyphile::MPV::PlayerSettings;
use Plugins::Lyphile::FFmpeg::PlayerSettings;

# The skin itself lives in HTML/Lyphile and is picked up automatically.

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lyphile',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_LYPHILE',
});
my $prefs = preferences('plugin.lyphile');

my $MAX_PORT_TRIES = 100;   # ports tried before giving up on finding a free one

# Services that get one TCP port per player. Ports are unique across all services and players.
#   zmq : ffmpeg azmq endpoint, stored as "tcp://127.0.0.1:<port>"
#   vlc : VLC Lua HTTP interface (--http-port), stored as the bare port
my %SERVICE = (
	zmq => { pref => 'zmq_port',      counter => 'zmq_next_port' },
	vlc => { pref => 'vlc_http_port', counter => 'vlc_next_port' },
);

$prefs->init({
	'zmq_next_port' => 5555,
	'vlc_next_port' => 8080,
	'mpv_ipc_dir'   => '/tmp/lyphile-mpv',
});

# Where the per-player logs (<mac>/*.log) are looked up by the settings page
sub logDir {
	return File::Spec::Functions::catdir(scalar Slim::Utils::OSDetect::dirsFor('log'), 'lyphile', 'remote_players');
}

# Environment inherited by the helpers Lyrion starts (vlc-Player): log folder, JSON-RPC address
sub setHelperEnv {
	my $port = preferences('server')->get('httpport') || 9000;
	$ENV{LMS_JSONRPC}    = "http://127.0.0.1:$port/jsonrpc.js";
	$ENV{LYPHILE_LOGDIR} = logDir();
}

# Where the helper scripts find the server: the folder of the plugin in the prefs of Lyrion
sub baseDir {
	return File::Spec::Functions::catdir(scalar Slim::Utils::OSDetect::dirsFor('prefs'), 'Lyphile');
}

# The address of Lyrion's JSON-RPC is written to <prefs>/Lyphile/jsonrpc. The helpers (Bin/jsonrpc)
# read it to ask Lyrion for the preferences of a player, which they cannot know otherwise.
sub writeJsonRpcFile {
	my $dir = baseDir();
	mkdir($dir, 0755) unless -d $dir;

	my $address = Slim::Utils::Network::serverAddr();
	my $port    = preferences('server')->get('httpport') || 9000;
	my $file    = File::Spec::Functions::catfile($dir, 'jsonrpc');

	if (open(my $fh, '>', $file)) {
		print $fh "http://$address:$port/jsonrpc.js";
		close $fh;
	}
	else {
		$log->error("Cannot write $file: $!");
	}
}

sub initPlugin {
	my $class = shift;

	setHelperEnv();
	writeJsonRpcFile();

	Slim::Web::Pages->addPageFunction('plugins/Lyphile/log.html', \&Plugins::Lyphile::Settings::logHandler);

	Slim::Web::Pages->addPageFunction('plugins/Lyphile/killvlc', \&Plugins::Lyphile::Settings::killVlcHandler);
	Slim::Web::Pages->addPageFunction('plugins/Lyphile/killmpv', \&Plugins::Lyphile::Settings::killMpvHandler);

	Plugins::Lyphile::Settings->new($class);
	Plugins::Lyphile::VLC::Control->init;
	Plugins::Lyphile::VLC::ControlLua->init;
	Plugins::Lyphile::FFmpeg::Control->init;
	Plugins::Lyphile::MPV::Control->init;
	Plugins::Lyphile::StreamInfo->init;
	Plugins::Lyphile::VLC::PlayerSettings->new;
	Plugins::Lyphile::VLC::PlayerSettingsLua->new;
	Plugins::Lyphile::MPV::PlayerSettings->new;
	Plugins::Lyphile::FFmpeg::PlayerSettings->new;

	Slim::Control::Request::subscribe(\&initClient, [['client'], ['new', 'reconnect']]);

	# players that connected before the plugin was loaded
	_init_ClientConfig($_) for Slim::Player::Client::clients();

	$class->SUPER::initPlugin(@_);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&initClient);
	Plugins::Lyphile::VLC::Control->shutdown;
	Plugins::Lyphile::VLC::ControlLua->shutdown;
	Plugins::Lyphile::FFmpeg::Control->shutdown;
	Plugins::Lyphile::MPV::Control->shutdown;
}

sub getDisplayName { 'PLUGIN_LYPHILE' }

sub initClient {
	my $request = shift;
	my $client  = $request->client() || return;

	$log->info('Initializing client ' . $client->id);
	_init_ClientConfig($client);
}

# The port a player has for a service, or undef
sub portOf {
	my ($client, $kind) = @_;

	my $value = $prefs->client($client)->get($SERVICE{$kind}{pref});
	return (defined $value && $value =~ /(\d+)$/) ? $1 + 0 : undef;
}

# Store a port for a player's service
sub setPort {
	my ($client, $kind, $port) = @_;

	$prefs->client($client)->set($SERVICE{$kind}{pref}, $kind eq 'zmq' ? "tcp://127.0.0.1:$port" : $port + 0);
}

# True if the port is not assigned to another player or service and nobody listens on it
sub portAvailable {
	my ($client, $kind, $port) = @_;

	for my $other ( Slim::Player::Client::clients() ) {
		for my $k (keys %SERVICE) {
			next if $client && $other->id eq $client->id && $k eq $kind;   # the value being replaced
			my $assigned = portOf($other, $k);
			return 0 if defined $assigned && $assigned == $port;
		}
	}

	# a successful listen proves the port is free (closed again right away)
	my $sock = IO::Socket::INET->new(
		Listen    => 1,
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto     => 'tcp',
		ReuseAddr => 1,
	);
	return $sock ? 1 : 0;
}

# Give a player the next free port of a service
sub _assignPort {
	my ($client, $kind) = @_;

	return if defined portOf($client, $kind);

	my $counter   = $SERVICE{$kind}{counter};
	my $next_port = $prefs->get($counter);

	# Skip ports that are used by another process or already assigned
	my $tries = 0;
	while ( $tries++ < $MAX_PORT_TRIES && !portAvailable($client, $kind, $next_port) ) {
		$log->warn("$kind port $next_port is not available, trying next");
		$next_port++;
	}

	setPort($client, $kind, $next_port);
	$prefs->set($counter, $next_port + 1);
}

# Random password for the VLC HTTP interface (it refuses to start without one)
sub _newPassword {
	my @chars = ('a' .. 'z', 'A' .. 'Z', 0 .. 9);
	return join '', map { $chars[ rand @chars ] } 1 .. 12;
}

# mpv --input-ipc-server path of a player: <dir>/<mac with dashes>.sock
sub mpvSocketFor {
	my $client = shift;
	(my $mac = lc $client->id) =~ s/:/-/g;
	return $prefs->get('mpv_ipc_dir') . "/$mac.sock";
}

# Give each player what the three services need (stored in the player prefs)
sub _init_ClientConfig {
	my ($client) = @_;

	_assignPort($client, 'zmq');
	_assignPort($client, 'vlc');

	my $cprefs = $prefs->client($client);
	$cprefs->set('vlc_http_password', _newPassword()) unless $cprefs->get('vlc_http_password');
	$cprefs->set('mpv_ipc_server', mpvSocketFor($client)) unless $cprefs->get('mpv_ipc_server');

	applyTranscoding($client) if $cprefs->get('selected_player');
}

# Output formats a player can be given: pref suffix => [ convert.conf format, -f option of the helper ]
my %OUT_FORMAT = (
	mp3 => [ 'mp3', 'mp3' ],
	flc => [ 'flc', 'flac' ],
	pcm => [ 'pcm', 'pcm' ],
);

# Source types of the rules, in the three groups of the settings page (the boxes audio, dvd and video of a player):
#   audio  the audio types, flac, mp3, wav, wavpack, ape ...
#   video  the video containers that the Play* plugins make playable (mkv, mpg, ts ...)
#   dvd    the DVD types of PlayDVD: disc images and folders (dvd, iso)
my %SOURCE_GROUP = (
	audio => [qw(aac aif alc alcx ape dff dsf flc mp3 mp4 mp4x mpc ogf ogg ops shn tak tta wav wma wmal wmap wvp wvpx)],
	video => [qw(avi mkv mp4v mpg mts webm)],
	dvd   => [qw(dvd iso)],
);

# Does the player take the rules of a group of file types (its box on the settings page)? All of them until it was set.
sub overrides {
	my ($client, $group) = @_;

	my $value = $prefs->client($client)->get("ov_$group");
	return defined $value ? ($value ? 1 : 0) : 1;
}

# The transcoding rules of one player, held in Lyrion's tables like Plugins::Daphile::Plugin does.
# Profile "<source>-<format>-*-<mac>" is tried before the rules of the stock convert.conf and of the
# other plugins. The rules of the three formats are removed first, then written again for the
# selected helper (Bin/<name>), the formats ticked on the settings page (mp3, flc, pcm) and the groups of
# file types ticked there (audio, dvd, video); no helper = no rules. A group that is not ticked keeps the
# stock rules.
sub applyTranscoding {
	my ($client) = @_;
	return unless $client;

	my $mac    = lc $client->id;
	my $cprefs = $prefs->client($client);
	my $helper = $cprefs->get('selected_player');

	foreach my $kind (sort keys %OUT_FORMAT) {
		my ($format, $option) = @{ $OUT_FORMAT{$kind} };

		foreach my $group (sort keys %SOURCE_GROUP) {
			my $wanted = $helper && $cprefs->get("tc_$kind") && overrides($client, $group);

			foreach my $source (@{ $SOURCE_GROUP{$group} }) {
				my $rule = "$source-$format-*-$mac";
				delete $Slim::Player::TranscodingHelper::capabilities{$rule};
				delete $Slim::Player::TranscodingHelper::commandTable{$rule};

				next unless $wanted;

				my $dvd = $group eq 'dvd';
				my $caps = { F => 'PATH=%f', T => 'START=-s %s', U => 'END=-d %w' };
				$caps->{R} = 'PATH=%F' if $dvd;
				$caps->{B} = 'BITRATE=-B %B' if $kind eq 'mp3';

				$Slim::Player::TranscodingHelper::capabilities{$rule} = $caps;
				$Slim::Player::TranscodingHelper::commandTable{$rule} = "[$helper] -m \$CLIENTID\$ -f $option \$START\$ \$END\$"
					. ($kind eq 'mp3' ? ' $BITRATE$' : '') . ($dvd ? ' $FILE$' : ' $PATH$');

				$log->info("Setting up rule: $rule");
			}
		}
	}
}

1;
