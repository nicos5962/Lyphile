package Plugins::Lyphile::Settings;

use strict;
use URI;
use warnings;
use parent qw(Slim::Web::Settings);

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use HTTP::Status qw(RC_NOT_FOUND RC_OK);
use JSON::XS qw(encode_json);

use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Web::HTTP;

my $log   = logger('plugin.lyphile');
my $prefs = preferences('plugin.lyphile');

sub name {
	return 'PLUGIN_LYPHILE';
}

sub page {
	return 'plugins/Lyphile/settings/basic.html';
}

sub new {
	my ($class, $main_plugin) = @_;
	return $class->SUPER::new;
}

# Force kill (SIGKILL) every process with the given name that Lyrion's user is allowed to signal.
# Answer: { ok, found, killed } as JSON.
sub _killProcesses {
	my ($name, $httpClient, $httpResponse) = @_;

	my @pids = grep { /^\d+$/ } split ' ', (`pgrep -x $name 2>/dev/null` // '');
	my $killed = @pids ? kill('KILL', @pids) : 0;
	$log->warn("force kill of $name: found " . scalar(@pids) . ', killed ' . $killed);

	my $json = encode_json({ ok => JSON::XS::true, found => scalar(@pids), killed => $killed + 0 });
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	return \$json;
}

# POST plugins/Lyphile/killvlc: every process named "vlc" (cvlc runs as vlc)
sub killVlcHandler {
	my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
	return _killProcesses('vlc', $httpClient, $httpResponse);
}

# POST plugins/Lyphile/killmpv: every process named "mpv"
sub killMpvHandler {
	my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
	return _killProcesses('mpv', $httpClient, $httpResponse);
}

# Per-player log files written by the transcoder: <log dir>/lyphile/remote_players/<mac>/<file>
my @PLAYER_LOGS = (
	{ type => 'transcode', file => 'transcode.log',      label => 'Transcode log' },
	{ type => 'ffmpeg',    file => 'ffmpeg-report.log',  label => 'FFmpeg report' },
	{ type => 'progress',  file => 'progress.log',       label => 'Progress log' },
	{ type => 'vlcplayer', file => 'vlc-player.log',     label => 'VLC player log' },
	{ type => 'vlc',       file => 'vlc.log',            label => 'VLC output' },
	{ type => 'vlcstatus', file => 'vlc-status.log',     label => 'VLC status' },
);

# { "<mac>/<type>" => { mac, label, file } } for every log file that exists
sub playerLogs {
	my %logs;

	foreach my $def (@PLAYER_LOGS) {
		foreach my $file (glob(catfile(Plugins::Lyphile::Plugin::logDir(), '*', $def->{file}))) {
			my ($mac) = $file =~ m{/([^/]+)/\Q$def->{file}\E$};
			$logs{"$mac/$def->{type}"} = { mac => $mac, label => $def->{label}, file => $file } if $mac;
		}
	}

	return \%logs;
}

# Media Server logs and one entry per player log file
sub logList {
	my $client_name = sub {
		my $mac = shift;
		my $client = Slim::Player::Client::getClient(lc $mac);
		return $client ? $client->name : $mac;
	};

	my @list = (
		{ label => 'Media Server log', url => 'server.log' },
		{ label => 'Media Scanner log', url => 'scanner.log' },
	);

	my $logs = playerLogs();

	foreach my $key (sort keys %$logs) {
		my ($mac, $type) = split m{/}, $key;
		push @list, {
			label => $logs->{$key}{label} . ': ' . $client_name->($mac),
			url   => "plugins/Lyphile/log.html?mac=$mac&type=$type",
		};
	}

	return \@list;
}

# Player log page: uses the core log viewer (refresh, search, line count, download)
sub logHandler {
	my ($client, $params, undef, $httpClient, $response) = @_;

	# The viewer of the core sends its own requests (the form that refreshes the page every 10 s, the lines and search
	# buttons: a POST; the Download link: a GET of the page without a query), and the server only passes the query
	# of a GET to the page function. The player and the type are then taken from the address of the request, or from
	# the page that sent it.
	my ($mac, $type) = ($params->{mac}, $params->{type});

	unless ($mac && $type) {
		my $request = $response->request;

		foreach my $url ($request && $request->uri, $request && $request->header('Referer')) {
			next unless $url;

			my %query = URI->new("$url")->query_form;
			($mac, $type) = @query{qw(mac type)} if $query{mac} && $query{type};
			last if $mac && $type;
		}
	}

	# only files found by playerLogs() can be shown, nothing taken from the request is used as a path
	my $entry = playerLogs()->{ ($mac || '') . '/' . ($type || '') };

	return Slim::Web::Pages::Common->logFileViewer($client, $params, $httpClient, $response, $entry->{file})
		if $entry;

	# a page function answers by returning a reference to the body, never a plain string, and it must not send the answer
	# itself as well: the server sends what the function returns, so both together answer the next request of the
	# connection with the wrong answer
	$log->warn(sprintf("log page: no log for mac='%s' type='%s' (logs found: %s, dir: %s)",
		$mac // '', $type // '', join(', ', sort keys %{ playerLogs() }) || 'none', Plugins::Lyphile::Plugin::logDir()));

	my $body = 'Log not found';
	$response->code(RC_NOT_FOUND);
	$response->content_type('text/plain; charset=utf-8');
	return \$body;
}

# Executable files of the plugin's Bin folder (sub folders and the jsonrpc helper are left out)
sub playerBinaries {
	my $dir = catfile(dirname(__FILE__), 'Bin');

	opendir(my $dh, $dir) or return [];
	my @bins = sort grep { $_ ne 'jsonrpc' && -f catfile($dir, $_) && -x _ } readdir($dh);
	closedir($dh);

	return \@bins;
}

sub handler {
	my ($class, $client, $params) = @_;

	my @errors;

	my $binaries = playerBinaries();

	$params->{'logs'} = logList();

	if ($params->{'saveSettings'}) {
		foreach my $kind (qw(zmq vlc)) {
			my $base = $params->{"${kind}_next_port"};
			if (defined $base && $base =~ /^\d+$/ && $base >= 1024 && $base <= 65535) {
				$prefs->set("${kind}_next_port", $base + 0);
			}
		}

		my $dir = $params->{'mpv_ipc_dir'};
		if (defined $dir) {
			$dir =~ s/^\s+|\s+$//g;
			$dir =~ s{/+$}{};
			if ($dir =~ m{^/[A-Za-z0-9_./-]+$} && $dir !~ m{\.\.}) {
				$prefs->set('mpv_ipc_dir', $dir);
			}
			else {
				push @errors, 'mpv socket directory: use an absolute path with letters, digits, _ . - /';
			}
		}

		foreach my $player (Slim::Player::Client::clients()) {
			my $mac = $player->id;

			my $selected = $params->{"selected_player_$mac"};
			if (defined $selected && (!length $selected || grep { $_ eq $selected } @$binaries)) {
				my $cprefs = $prefs->client($player);
				$cprefs->set('selected_player', $selected);
				$cprefs->set("tc_$_", (length $selected && $params->{"tc_${_}_$mac"}) ? 1 : 0) foreach qw(mp3 flc pcm);
				$cprefs->set("ov_$_", (length $selected && $params->{"ov_${_}_$mac"}) ? 1 : 0) foreach qw(audio dvd video);
				Plugins::Lyphile::Plugin::applyTranscoding($player);
			}

			# one TCP port per service: ffmpeg zmq, VLC HTTP
			foreach my $kind (qw(zmq vlc)) {
				my $port = $params->{"${kind}_port_$mac"};
				next unless defined $port && length $port;

				$port =~ s/^\s+|\s+$//g;
				$port =~ s{^tcp://127\.0\.0\.1:}{};

				my $current = Plugins::Lyphile::Plugin::portOf($player, $kind);
				next if defined $current && $current eq $port;

				if ($port !~ /^\d+$/ || $port < 1024 || $port > 65535) {
					push @errors, $player->name . " ($kind): invalid port";
				}
				elsif (!Plugins::Lyphile::Plugin::portAvailable($player, $kind, $port)) {
					push @errors, $player->name . " ($kind): port $port is not available";
				}
				else {
					Plugins::Lyphile::Plugin::setPort($player, $kind, $port);
				}
			}

			my $password = $params->{"vlc_password_$mac"};
			if (defined $password) {
				$password =~ s/^\s+|\s+$//g;
				if ($password =~ /^[A-Za-z0-9_.-]{4,64}$/) {
					$prefs->client($player)->set('vlc_http_password', $password);
				}
				elsif (length $password) {
					push @errors, $player->name . ' (vlc): password needs 4-64 letters, digits, _ . -';
				}
			}

			my $socket = $params->{"mpv_ipc_$mac"};
			if (defined $socket) {
				$socket =~ s/^\s+|\s+$//g;
				if ($socket =~ m{^/[A-Za-z0-9_./-]+$} && $socket !~ m{\.\.}) {
					$prefs->client($player)->set('mpv_ipc_server', $socket);
				}
				elsif (length $socket) {
					push @errors, $player->name . ' (mpv): invalid socket path';
				}
			}
		}
	}

	$params->{'warning'} = join('<br>', @errors) if @errors;

	$params->{'icon'}          = 'plugins/Lyphile/html/images/lyphile-icon.png';
	$params->{'player_bins'}      = $binaries;
	$params->{'zmq_next_port'} = $prefs->get('zmq_next_port');
	$params->{'vlc_next_port'} = $prefs->get('vlc_next_port');
	$params->{'mpv_ipc_dir'}   = $prefs->get('mpv_ipc_dir');

	my $bins = check_binaries();
	$params->{'ffmpeg_bins'} = $bins->{ffmpeg};
	$params->{'vlc_bins'}    = $bins->{vlc};
	$params->{'mpv_bins'}    = $bins->{mpv};
	$params->{'general_bins'} = $bins->{general};
	$params->{'ffmpeg_conf'} = $bins->{ffmpeg_conf};

	my @devices;
	foreach my $player (Slim::Player::Client::clients()) {
		my $cprefs = $prefs->client($player);
		push @devices, {
			name         => $player->name,
			mac          => $player->id,
			zmq_port     => Plugins::Lyphile::Plugin::portOf($player, 'zmq'),
			vlc_port     => Plugins::Lyphile::Plugin::portOf($player, 'vlc'),
			vlc_password => $cprefs->get('vlc_http_password'),
			mpv_ipc      => $cprefs->get('mpv_ipc_server'),
			player_bin   => $cprefs->get('selected_player') || '',
			tc_mp3       => $cprefs->get('tc_mp3'),
			tc_flc       => $cprefs->get('tc_flc'),
			tc_pcm       => $cprefs->get('tc_pcm'),
			ov_audio     => Plugins::Lyphile::Plugin::overrides($player, 'audio'),
			ov_dvd       => Plugins::Lyphile::Plugin::overrides($player, 'dvd'),
			ov_video     => Plugins::Lyphile::Plugin::overrides($player, 'video'),
		};
	}
	$params->{'devices'} = \@devices;

	return $class->SUPER::handler($client, $params);
}

sub find_command {
	my $cmd = shift;

	my $path = Slim::Utils::Misc::findbin($cmd);
	return $path if $path;

	foreach my $dir (split /:/, $ENV{PATH} || '') {
		return "$dir/$cmd" if -x "$dir/$cmd";
	}
	return;
}

# Status of the external programs, grouped by section: { ffmpeg => [...], vlc => [...], mpv => [...],
# general => [...] }
sub check_binaries {
	my (@ffmpeg, @vlc, @mpv, @general);

	my $ffmpeg = find_command('ffmpeg');
	my ($ffver, %lib) = ffmpeg_versions($ffmpeg);

	push @ffmpeg, { name => 'ffmpeg', ok => $ffmpeg ? 'yes' : 'no', path => $ffmpeg || '', version => $ffver, desc => 'Audio decoding and transcoding' };

	my $azmq = 'no';
	if ($ffmpeg) {
		my $filters = `"$ffmpeg" -hide_banner -filters 2>&1`;
		$azmq = 'yes' if defined $filters && $filters =~ /\bazmq\b/;
	}
	push @ffmpeg, { name => 'ffmpeg + azmq', ok => $azmq, path => '', version => $lib{libavfilter}, desc => 'ZMQ filter, lets ffmpeg be controlled while playing (libavfilter)' };

	my $conf = '';
	if ($ffmpeg) {
		$conf = `"$ffmpeg" -hide_banner -buildconf 2>&1`;
		$conf = '' unless defined $conf;
	}

	push @ffmpeg, { name => 'ffmpeg + soxr', ok => ($conf =~ /--enable-libsoxr\b/ ? 'yes' : 'no'), path => '', version => $lib{libswresample}, desc => 'SoX resampler (libsoxr), high quality resampling (libswresample)' };

	my $dvd = 'no';
	if ($ffmpeg) {
		my $demuxers = `"$ffmpeg" -hide_banner -demuxers 2>&1`;
		$dvd = 'yes' if defined $demuxers && $demuxers =~ /\bdvdvideo\b/;
	}
	push @ffmpeg, { name => 'ffmpeg + dvdvideo', ok => $dvd, path => '', version => $lib{libavformat}, desc => 'DVD demuxer (libdvdnav / libdvdread), plays DVD ISOs and VIDEO_TS (libavformat)' };

	my $zmqsend = Slim::Utils::Misc::findbin('zmqsend');
	if ( !$zmqsend ) {
		$zmqsend = qx(find /config/ -type f -name "zmqsend" 2>/dev/null);
		chomp $zmqsend if defined $zmqsend;
		($zmqsend) = split /\n/, $zmqsend if $zmqsend;   # keep the first match
	}
	push @ffmpeg, { name => 'zmqsend', ok => $zmqsend ? 'yes' : 'no', path => $zmqsend || '', version => zmqsend_version($zmqsend), desc => 'Sends commands to the player\'s zmq port' };

	# VLC: the HTTP interface is a Lua module, so it is checked with the module list
	my $vlc = find_command('vlc') || find_command('cvlc');
	my $vlcver = '';
	my $http = 'no';
	if ($vlc) {
		my $out = `timeout 15 "$vlc" --version 2>&1 </dev/null`;
		$out = '' unless defined $out;
		($vlcver) = $out =~ /VLC version (\S+)/;
		my $mods = `timeout 20 "$vlc" -I dummy --list --no-color 2>&1 </dev/null`;
		$http = 'yes' if defined $mods && $mods =~ /\bhttp\b/;
	}
	my $player = find_command('vlc-Player');
	push @vlc, { name => 'vlc-Player', ok => $player ? 'yes' : 'no', path => $player || '', version => '', desc => 'Plugin helper: VLC to ffmpeg, audio to Lyrion' };
	push @vlc, { name => 'vlc', ok => $vlc ? 'yes' : 'no', path => $vlc || '', version => $vlcver || '', desc => 'VLC media player (cvlc for headless use)' };
	push @vlc, { name => 'vlc + http', ok => $http, path => '', version => '', desc => 'Lua HTTP interface (--extraintf=http), used for remote control' };

	# mpv
	my $mpv = find_command('mpv');
	my $mpvver = '';
	if ($mpv) {
		my $out = `timeout 15 "$mpv" --version 2>&1 </dev/null`;
		$out = '' unless defined $out;
		($mpvver) = $out =~ /^mpv (\S+)/m;
	}
	push @mpv, { name => 'mpv', ok => $mpv ? 'yes' : 'no', path => $mpv || '', version => $mpvver || '', desc => 'mpv media player, controlled through --input-ipc-server' };

	# tools of the helper scripts: jq and curl for Bin/jsonrpc (the preferences of a player)
	my $jq = find_command('jq');
	my $jqver = '';
	if ($jq) {
		my $out = `timeout 15 "$jq" --version 2>&1 </dev/null`;
		$out = '' unless defined $out;
		($jqver) = $out =~ /^jq-?(\S+)/m;
	}
	push @general, { name => 'jq', ok => $jq ? 'yes' : 'no', path => $jq || '', version => $jqver || '', desc => 'JSON parser, reads the answers of Lyrion in the helper scripts' };

	my $curl = find_command('curl');
	my $curlver = '';
	if ($curl) {
		my $out = `timeout 15 "$curl" --version 2>&1 </dev/null`;
		$out = '' unless defined $out;
		($curlver) = $out =~ /^curl (\S+)/m;
	}
	push @general, { name => 'curl', ok => $curl ? 'yes' : 'no', path => $curl || '', version => $curlver || '', desc => 'Sends the requests of Bin/jsonrpc to Lyrion' };

	(my $confline = $conf) =~ s/^\s+|\s+$//g;
	return { ffmpeg => \@ffmpeg, vlc => \@vlc, mpv => \@mpv, general => \@general, ffmpeg_conf => $confline };
}

# ("4.4.2", libavfilter => "7.110.100", ...) from `ffmpeg -version`
sub ffmpeg_versions {
	my $ffmpeg = shift or return ('');

	my $out = `"$ffmpeg" -hide_banner -version 2>&1`;
	return ('') unless defined $out;

	my ($ver) = $out =~ /^ffmpeg version (\S+)/m;
	my %lib;
	while ($out =~ /^(lib\w+)\s+(\d+\s*\.\s*\d+\s*\.\s*\d+)/mg) {
		my ($name, $v) = ($1, $2);
		$v =~ s/\s+//g;
		$lib{$name} = $v;
	}
	return ($ver || '', %lib);
}

# zmqsend has no version option: take it from its usage text when it prints one
sub zmqsend_version {
	my $zmqsend = shift or return '';

	my $out = `timeout 2 "$zmqsend" -h 2>&1 </dev/null`;
	return ($out && $out =~ /version\s+(\S+)/i) ? $1 : '';
}

1;
