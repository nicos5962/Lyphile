package Plugins::Lyphile::MPV::Control;

# Endpoints of the mpv player page, and the Lyrion events passed on to mpv. mpv (Bin/mpv-Player) is
# controlled through its JSON IPC (--input-ipc-server): one JSON object per line over a unix
# socket, each request with a "request_id", answered by {"request_id", "error", "data"} among
# unrelated {"event": ...} lines. The socket is the player's "IPC server" pref (mpv_ipc_server),
# set on the Lyphile settings page.
#
#   POST plugins/Lyphile/mpv/rcstatus   player=<mac>   is mpv's IPC socket answering; when it is, also
#                                                      the input, the audio streams, the chapters
#                                                      and 8 lines of audio statistics
#   POST plugins/Lyphile/mpv/aid        player=<mac>&id=<audio track id>   switch the audio track
#                                                      (set_property aid), read it back; the answer
#                                                      has the streams and "confirmed"
#   POST plugins/Lyphile/mpv/chapter    player=<mac>&id=<chapter, from 0>  switch the chapter
#                                                      (set_property chapter), read it back; the
#                                                      answer has the chapters and "confirmed"
#
#   POST plugins/Lyphile/mpv/atrack     the same as aid (the name the player pages use)
#   POST plugins/Lyphile/mpv/transport  player=<mac>&action=<pause|stop>   pause (toggle) or stop the Lyrion player;
#                                                      the events below pass it on to mpv
#   POST plugins/Lyphile/mpv/tc         player=<mac>&bits=<16|24>&rate=<44100|48000|96000>   PCM settings (prefs tc_bits,
#                                                      tc_rate); refused while mpv runs
#
# rcstatus also has now { state, time, length, artist, album, title, cover } and tc { bits, rate }. There is no
# equalizer for mpv.
#
# Every answer is JSON: { ok => true|false, error => "...", ... }. The streams and chapters are
# lists of { id, text, selected }, as for the VLC page.
#
# A switch is also written to the log of the run in progress,
# <log dir>/lyphile/remote_players/<mac>/mpv-transcode-<mac>.log (Bin/mpv-Player appends that file
# to transcode.log when the run ends), as:
#     Command: aid 2 -> 2 - ac3 - eng - Stereo
#
# Events of Lyrion's own player: "playlist newsong" connects to the mpv of the player (see _attach), and these are passed
# on to mpv of that player (when it is running):
#   playlist pause 1 / 0   set_property pause yes / no   (not a toggle: no state to look at)
#   playlist stop          stop

use strict;
use warnings;

use HTTP::Status qw(RC_OK);
use IO::Select;
use IO::Socket::UNIX;
use JSON::XS;
use Time::HiRes ();
use URI::Escape ();

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Web::HTTP;
use Slim::Web::Pages;

use Plugins::Lyphile::VLC::ControlLua;    # the track and artwork of Lyrion, and the PCM prefs: the same for every page

my $log   = logger('plugin.lyphile');
my $prefs = preferences('plugin.lyphile');

my $LOG_BASE;    # set by tests; normally Plugins::Lyphile::Plugin::logDir()

my %ENDPOINT = (
	rcstatus  => \&_rcstatus,
	aid       => \&_aid,
	atrack    => \&_aid,          # the name the player pages use
	chapter   => \&_chapter,
	transport => \&_transport,
	tc        => \&_tc,
);

sub init {
	Slim::Control::Request::subscribe(\&_onPlaylist, [['playlist'], ['pause', 'stop', 'newsong']]);

	foreach my $name (keys %ENDPOINT) {
		my $handler = $ENDPOINT{$name};

		Slim::Web::Pages->addPageFunction("plugins/Lyphile/mpv/$name", sub {
			my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
			_send_json($httpClient, $httpResponse, $handler->($params));
		});
	}
}

sub shutdown {
	Slim::Control::Request::unsubscribe(\&_onPlaylist);
}

sub _send_json {
	my ($httpClient, $httpResponse, $data) = @_;

	my $json = encode_json($data);
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	$httpResponse->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $httpResponse, \$json, undef, undef);
}

# ------------------------------------------------------------------------------
# The IPC
# ------------------------------------------------------------------------------

# The player of a request from its MAC address, or undef
sub _client_of {
	my $mac = lc(shift // '');
	return unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	return Slim::Player::Client::getClient($mac);
}

# The socket path stored for the player, or undef
sub _socket_of {
	my $client = shift;

	my $path = $prefs->client($client)->get('mpv_ipc_server');
	return unless defined $path && $path =~ m{^/[A-Za-z0-9_./-]+$} && $path !~ m{\.\.};
	return $path;
}

# mpv answers an IPC request only between two writes of its audio to the pipe: one request every 1.5 s or so while
# ffmpeg takes the audio at real time (and none during the first seconds). Asking for the properties at every poll
# would never finish, and Lyrion's main loop must not wait for it. So there is one persistent connection per socket,
# on which the properties the page shows are observed once (observe_property): mpv then sends every change by itself,
# and the poll only reads what has arrived. Commands are written and not waited for either.
my %IPC;    # socket path => { path, sock, buf, id, values => {}, file, pending => { request id => property }, asked => { property => time } }

# The properties the page shows, in the order they are observed (the first ones are the first to arrive)
my @PAGE_PROPERTIES = qw(
	path pause time-pos duration track-list chapter-list chapter media-title
	audio-params audio-bitrate audio-codec-name speed volume options/dvd-device
);

# The connection to mpv's IPC socket, or undef when mpv is not running (no socket, or it closed it)
sub _ipc {
	my $path = shift;

	return unless defined $path;
	unless (-S $path) { _ipc_drop($IPC{$path}) if $IPC{$path}; return }

	if (my $c = $IPC{$path}) {
		_pump($c, 0);
		return $IPC{$path};
	}

	my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path, Timeout => 1) or return;
	$sock->blocking(0);

	my $c = $IPC{$path} = { path => $path, sock => $sock, buf => '', id => 0, values => {}, pending => {}, asked => {} };

	my $requests = '';
	my $n = 0;
	foreach my $property (@PAGE_PROPERTIES) {
		$requests .= encode_json({ command => ['observe_property', ++$n, $property], request_id => ++$c->{id} }) . "\n";
	}
	syswrite($sock, $requests);

	return $c;
}

sub _ipc_drop {
	my $c = shift or return;
	close $c->{sock};
	delete $IPC{ $c->{path} };
}

# Read what mpv sent (waiting at most $wait seconds for the first data) and keep the values of the observed properties
sub _pump {
	my ($c, $wait) = @_;

	my $select = IO::Select->new($c->{sock});

	while ($select->can_read($wait)) {
		$wait = 0;
		my $n = sysread($c->{sock}, my $chunk, 65536);
		unless (defined $n) {
			last if $!{EAGAIN} || $!{EWOULDBLOCK};
			return _ipc_drop($c);
		}
		return _ipc_drop($c) unless $n;     # mpv closed the socket
		$c->{buf} .= $chunk;
	}

	while ($c->{buf} =~ s/^([^\n]*)\n//) {
		my $message = eval { decode_json($1) } or next;
		next unless ref $message eq 'HASH';

		my ($property, $data);

		if (defined $message->{request_id}) {
			# the answer to a get_property of _refresh
			$property = delete $c->{pending}{ $message->{request_id} } or next;
			$data = ($message->{error} // '') eq 'success' ? $message->{data} : undef;
		}
		elsif (($message->{event} // '') eq 'property-change' && defined $message->{name}) {
			($property, $data) = ($message->{name}, $message->{data});
		}
		else { next }

		$data = $data ? 1 : 0 if JSON::XS::is_bool($data);
		undef $data if ref $data && ref $data !~ /^(ARRAY|HASH)$/;

		# another file: nothing that was remembered is true any more
		if ($property eq 'path' && defined $data && (($c->{file} // '') ne $data)) {
			$c->{values} = {};
			$c->{file}   = $data;
		}

		if (defined $data) { $c->{values}{$property} = $data } else { delete $c->{values}{$property} }
	}
}

# mpv does not always send the new value of a property after it was unavailable for a while: the audio format
# (audio-params) stays unavailable after the audio track was switched, although a request gets it. So a property of
# the audio that is missing while a file plays is asked for, at most every 3 s (one request: mpv answers one a second
# or so).
my @REFRESHED = qw(audio-params audio-codec-name audio-bitrate);

sub _refresh {
	my $c = shift;

	return unless defined $c->{values}{path};

	my $now = Time::HiRes::time();
	foreach my $property (@REFRESHED) {
		next if exists $c->{values}{$property};
		next if $now - ($c->{asked}{$property} // 0) < 3;

		$c->{asked}{$property} = $now;
		my $id = ++$c->{id};
		$c->{pending}{$id} = $property;
		syswrite($c->{sock}, encode_json({ command => ['get_property', $property], request_id => $id }) . "\n");
		last;
	}
}

# The latest values of the observed properties, or undef when mpv is not running
sub _snapshot {
	my ($path) = @_;

	my $c = _ipc($path) or return;
	_pump($c, 0.05);
	_refresh($c) if $IPC{$path};

	return $IPC{$path} ? $IPC{$path}{values} : undef;
}

# A command to mpv, not waited for. Returns whether it was sent.
sub _command {
	my ($path, @command) = @_;

	my $c = _ipc($path) or return 0;
	my $id = ++$c->{id};
	return defined syswrite($c->{sock}, encode_json({ command => \@command, request_id => $id }) . "\n") ? 1 : 0;
}

# ------------------------------------------------------------------------------
# What the page shows
# ------------------------------------------------------------------------------

# The input as an URL-like string, of which the page shows the file name. A disc is
# "<device>#<title>", the device being the ISO or the VIDEO_TS folder.
sub _input {
	my $v = shift;

	my $path = $v->{path};
	return '' unless defined $path && length $path;

	if ($path =~ m{^dvd://(\d*)}) {
		my $title  = $1;
		my $device = $v->{'options/dvd-device'} // '';
		$path = $device . (length $title ? "#$title" : '');
	}

	return $path =~ m{^[a-z][a-z0-9+.-]*://}i ? $path : URI::Escape::uri_escape_utf8($path, '^A-Za-z0-9\-_.~/#');
}

# The audio tracks Bin/mpv-Player found to have data at the start (its file audio-streams.txt, written for the run in
# progress): { aid => 1 }, or undef when it wrote none (all the tracks are usable)
sub _usable_aids {
	my $mac = lc(shift // '');
	$mac =~ s/:/-/g;

	my $base = $LOG_BASE // Plugins::Lyphile::Plugin::logDir();
	open(my $fh, '<', "$base/$mac/audio-streams.txt") or return;
	my @aids = grep { /^\d+$/ } split ' ', (<$fh> // '');
	close $fh;

	return @aids ? { map { $_ => 1 } @aids } : undef;
}

# The audio tracks of "track-list": { id, text, selected }. The text is what there is of codec,
# language, title, sample rate, channels and bitrate. Only the usable tracks when the script says which.
sub _audio_tracks {
	my ($v, $mac) = @_;

	my $usable = defined $mac ? _usable_aids($mac) : undef;

	my $list = $v->{'track-list'};
	return () unless ref $list eq 'ARRAY';

	my @streams;
	foreach my $track (grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'audio' && (!$usable || $usable->{ $_->{id} }) } @$list) {
		my $channels = $track->{'demux-channels'} // ($track->{'demux-channel-count'} ? "$track->{'demux-channel-count'} ch" : undef);
		my $bitrate  = $track->{'demux-bitrate'}  ? sprintf('%d kb/s', $track->{'demux-bitrate'} / 1000 + 0.5) : undef;
		my $rate     = $track->{'demux-samplerate'} ? "$track->{'demux-samplerate'} Hz" : undef;

		my $text = join ' - ', grep { defined && length } ($track->{codec}, $track->{lang}, $track->{title}, $rate, $channels, $bitrate);

		push @streams, {
			id       => $track->{id},
			text     => length($text) ? $text : "track $track->{id}",
			selected => $track->{selected} ? \1 : \0,
		};
	}

	return @streams;
}

# Edit distance of two short strings
sub _distance {
	my ($x, $y) = @_;

	my @row = (0 .. length $y);
	for my $i (1 .. length $x) {
		my @new = ($i);
		for my $j (1 .. length $y) {
			my $cost = substr($x, $i - 1, 1) eq substr($y, $j - 1, 1) ? 0 : 1;
			my $best = $row[$j - 1] + $cost;
			$best = $row[$j] + 1     if $row[$j] + 1     < $best;
			$best = $new[$j - 1] + 1 if $new[$j - 1] + 1 < $best;
			push @new, $best;
		}
		@row = @new;
	}

	return $row[-1];
}

# A Matroska chapter can carry its title in several languages, which mpv joins with " / " ("Opening credits / Opening
# Credits"). When the text is the same title twice (the second may differ by a letter or the case), the first is
# enough; a title that really has a " / " in it stays as it is.
sub _one_title {
	my $title = shift // '';

	my @parts = split m{\s+/\s+}, $title;
	return $title if @parts < 2;

	my $norm = sub { lc(shift) =~ s/[^[:alnum:]]+//gr };

	for my $k (1 .. $#parts) {
		my ($left, $right) = (join(' / ', @parts[0 .. $k - 1]), join(' / ', @parts[$k .. $#parts]));
		my ($nl, $nr) = ($norm->($left), $norm->($right));
		next unless length $nl && length $nr && abs(length($nl) - length($nr)) <= 3;
		return $left if _distance($nl, $nr) <= (length($nl) > 12 ? 2 : 1);
	}

	return $title;
}

# The chapters of "chapter-list": { id (from 0), text (from 1, with the title when it says more
# than the number), selected }
sub _chapters {
	my $v = shift;

	my $list = $v->{'chapter-list'};
	return () unless ref $list eq 'ARRAY' && @$list;

	my $current = $v->{chapter};

	my @chapters;
	for my $i (0 .. $#$list) {
		my $title = ref $list->[$i] eq 'HASH' ? ($list->[$i]{title} // '') : '';

		$title = _one_title($title);

		my $text  = $i + 1;
		$text .= " - $title" if length $title && $title !~ /^chapter\s*\d+$/i;

		push @chapters, { id => $i, text => $text, selected => (defined $current && $current == $i) ? \1 : \0 };
	}

	return @chapters;
}

sub _hms {
	my $seconds = shift;
	return '' unless defined $seconds && $seconds =~ /^[\d.]+$/;
	return sprintf('%02d:%02d:%02d', $seconds / 3600, ($seconds % 3600) / 60, $seconds % 60);
}

# 8 lines of audio statistics for the page
sub _stats {
	my $v = shift;

	my $params  = $v->{'audio-params'};
	$params = {} unless ref $params eq 'HASH';
	my $bitrate = $v->{'audio-bitrate'};
	my $speed   = $v->{speed};
	my $volume  = $v->{volume};
	my ($pos, $duration) = (_hms($v->{'time-pos'}), _hms($v->{duration}));

	my @rows = (
		['codec',         $v->{'audio-codec-name'} // ''],
		['format',        $params->{format} // ''],
		['sample rate',   $params->{samplerate} ? "$params->{samplerate} Hz" : ''],
		['channels',      $params->{'hr-channels'} // $params->{channels} // ''],
		['audio bitrate', $bitrate ? sprintf('%d kb/s', $bitrate / 1000 + 0.5) : ''],
		['speed',         defined $speed  ? sprintf('%.2f', $speed) : ''],
		['volume',        defined $volume ? sprintf('%d', $volume + 0.5) : ''],
		['position',      length $pos ? ($pos . (length $duration ? " / $duration" : '')) : ''],
	);

	return map { sprintf('%-14s : %s', @$_) } @rows;
}


sub _rcstatus {
	my $params = shift;

	my $client = _client_of($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $path   = _socket_of($client)           or return { ok => \0, error => 'no mpv ipc server set for this player' };

	my $mac = lc $client->id;
	my %extra = (tc => Plugins::Lyphile::VLC::ControlLua::_tc_state($mac));

	my ($active, $input, @streams, @chapters, @stats, %now) = (0, '');
	if (my $v = _snapshot($path)) {
		$active = 1;

		$input    = _input($v);
		@streams  = _audio_tracks($v, $mac);
		@chapters = _chapters($v);
		@stats    = _stats($v);

		%now = (
			# Lyrion's own state: mpv's pause property only follows Lyrion's pause a second or two later
			state  => (eval { Slim::Player::Source::playmode($client) } // '') eq 'pause' ? 'paused' : ($v->{pause} ? 'paused' : 'playing'),
			time   => defined $v->{'time-pos'} ? int($v->{'time-pos'} + 0) : undef,
			length => defined $v->{duration}   ? int($v->{duration} + 0)   : undef,
		);

		# artist, album, title and artwork are Lyrion's; without a title the name mpv gives the item is used
		my ($artist, $album, $title) = eval { Plugins::Lyphile::VLC::ControlLua::_lyrion_track($mac) };
		@now{qw(artist album title)} = (defined $title && length $title) ? ($artist, $album, $title) : ('', '', $v->{'media-title'} // '');
		$now{cover} = eval { Plugins::Lyphile::VLC::ControlLua::_lyrion_cover($mac) } // '';
	}

	return { ok => \1, active => $active ? \1 : \0, input => $input, streams => \@streams, chapters => \@chapters, stats => \@stats, now => \%now, %extra, socket => $path };
}

# ------------------------------------------------------------------------------
# Switches
# ------------------------------------------------------------------------------

# Lines appended to the log of the run in progress. Nothing is written when there is no such file:
# it only exists while Bin/mpv-Player runs.
sub _runLog {
	my ($client, @lines) = @_;

	(my $mac = lc $client->id) =~ s/:/-/g;
	my $base = $LOG_BASE // Plugins::Lyphile::Plugin::logDir();
	my $file = "$base/$mac/mpv-transcode-$mac.log";
	return unless -f $file;

	open(my $fh, '>>', $file) or return;
	print $fh map { "$_\n" } @lines;
	close $fh;
}

# The track and the chapter are written to mpv and not waited for (see the IPC above): "confirmed" means the command was
# sent, and the answer shows the lists as they are with the choice marked; the next poll of the page shows what mpv did.
sub _aid {
	my $params = shift;

	my $client = _client_of($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $path   = _socket_of($client)           or return { ok => \0, error => 'no mpv ipc server set for this player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad audio track' } unless defined $id && $id =~ /^\d{1,4}$/;

	my $v = _snapshot($path) or return { ok => \0, error => 'mpv is not running' };

	my @streams = _audio_tracks($v, $client->id);
	return { ok => \0, error => 'unknown audio track' } unless grep { $_->{id} == $id } @streams;

	_command($path, 'set_property', 'aid', $id + 0) or return { ok => \0, error => 'mpv is not running' };

	$_->{selected} = $_->{id} == $id ? \1 : \0 for @streams;

	my ($now) = grep { ${ $_->{selected} } } @streams;
	_runLog($client, "  Command: aid $id -> $now->{id} - $now->{text}");

	return { ok => \1, confirmed => \1, streams => \@streams };
}

sub _chapter {
	my $params = shift;

	my $client = _client_of($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $path   = _socket_of($client)           or return { ok => \0, error => 'no mpv ipc server set for this player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad chapter' } unless defined $id && $id =~ /^\d{1,3}$/;

	my $v = _snapshot($path) or return { ok => \0, error => 'mpv is not running' };

	my @chapters = _chapters($v);
	return { ok => \0, error => 'unknown chapter' } unless grep { $_->{id} == $id } @chapters;

	_command($path, 'set_property', 'chapter', $id + 0) or return { ok => \0, error => 'mpv is not running' };

	$_->{selected} = $_->{id} == $id ? \1 : \0 for @chapters;
	_runLog($client, "  Command: chapter $id -> chapter $id/" . scalar(@chapters));

	return { ok => \1, confirmed => \1, chapters => \@chapters };
}

# ------------------------------------------------------------------------------
# Transport, PCM settings
# ------------------------------------------------------------------------------

# The pause and stop buttons of the page act on Lyrion's player, as its own buttons do; the events below then
# reach mpv, so that Lyrion and mpv stay one
sub _transport {
	my $params = shift;

	my $client = _client_of($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $action = $params->{action} // '';
	return { ok => \0, error => 'bad action' } unless $action eq 'pause' || $action eq 'stop';

	$client->execute([$action]);
	$log->info("mpv page: $action of " . $client->id);

	return { ok => \1 };
}

# PCM settings: prefs read by Bin/mpv-Player when a track starts, so refused while mpv runs
sub _tc {
	my $params = shift;

	my $client = _client_of($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $path   = _socket_of($client);

	return { ok => \0, error => 'bad bits' } if defined $params->{bits} && $params->{bits} !~ /^(16|24)$/;
	return { ok => \0, error => 'bad rate' } if defined $params->{rate} && $params->{rate} !~ /^(44100|48000|96000)$/;

	return { ok => \0, error => 'playing' } if $path && _ipc($path);

	my $cprefs = $prefs->client($client);
	$cprefs->set('tc_bits', $params->{bits} + 0) if defined $params->{bits};
	$cprefs->set('tc_rate', $params->{rate} + 0) if defined $params->{rate};

	return { ok => \1, tc => Plugins::Lyphile::VLC::ControlLua::_tc_state(lc $client->id) };
}

# ------------------------------------------------------------------------------
# Lyrion events
# ------------------------------------------------------------------------------

# "playlist pause <0|1>" and "playlist stop" of a player, passed on to its mpv
# Connect to the mpv of a player as soon as its socket is there (it appears about a second after the track starts), so
# that the observed properties have arrived when the page is opened
sub _attach {
	my ($client, $tries) = @_;

	my $path = _socket_of($client) or return;
	return if _ipc($path);

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, \&_attach, $tries + 1) if $tries < 40;
}

sub _onPlaylist {
	my $request = shift;

	my $client = $request->client or return;
	my $what   = $request->getRequest(1) or return;

	if ($what eq 'newsong') {
		return unless ($prefs->client($client)->get('selected_player') // '') eq 'mpv-Player';
		Slim::Utils::Timers::killTimers($client, \&_attach);
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&_attach, 0);
		return;
	}

	my $path = _socket_of($client) or return;
	_ipc($path) or return;    # no mpv for this player: nothing to do

	if ($what eq 'stop') {
		_command($path, 'stop');
		$log->info('mpv: stop sent to ' . $client->id);
	}
	elsif ($what eq 'pause') {
		my $paused = $request->getRequest(2);
		$paused = $client->isPaused ? 1 : 0 unless defined $paused;

		_command($path, 'set_property', 'pause', $paused ? JSON::XS::true : JSON::XS::false);
		$log->info('mpv: ' . ($paused ? 'pause' : 'resume') . ' sent to ' . $client->id);
	}
}

1;
