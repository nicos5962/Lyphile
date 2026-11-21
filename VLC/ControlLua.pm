package Plugins::Lyphile::VLC::ControlLua;

# Endpoints of the VLC player page (Lua version): the same job as Plugins::Lyphile::VLC::Control, but
# VLC is reached through its Lua HTTP interface (Bin/vlc-Player-lua starts VLC with
# --extraintf=http --http-host=127.0.0.1 --http-port=<port> --http-password=<password>) instead of the
# oldrc interface. Port and password are the "vlc_http_port" and "vlc_http_password" values of the
# player's preferences. The HTTP interface is asked with basic authentication (empty user name).
#
#   POST plugins/Lyphile/vlclua/atrack     player=<mac>&id=<audio track id>   switch the audio track
#                                                      (?command=audio_track&val=<id>), then read the
#                                                      status again: "confirmed" is true when VLC accepted
#                                                      the command and still answers
#   POST plugins/Lyphile/vlclua/chapter    player=<mac>&id=<chapter number, from 0>   switch the chapter
#                                                      (?command=chapter&val=<id>), then read the status
#                                                      again: "confirmed" is true when VLC reports it
#   POST plugins/Lyphile/vlclua/transport  player=<mac>&action=<pause|stop>   pause (a toggle: pauses, or
#                                                      resumes when paused) or stop the Lyrion player; the
#                                                      events below pass it on to VLC
#   POST plugins/Lyphile/vlclua/rcstatus   player=<mac>   is VLC's HTTP interface answering (see
#                                                      Bin/vlc-Player-lua); when it is, also the input
#                                                      (playlist.json), the audio streams and chapters
#                                                      (information of status.json), the statistics, and
#                                                      "now": state, time, length, artist, album, title
#
#   POST plugins/Lyphile/vlclua/eq         player=<mac>&(eq=on|off | band=<0-9>&value=<dB> | gain=<dB> | reset=1)
#                                                      the equalizer commands of the HTTP interface
#                                                      (enableeq, equalizer, preamp); also in "rcstatus" as
#                                                      "eq". Note: VLC applies its equalizer to its own audio
#                                                      output, which is not used while Bin/vlc-Player-lua
#                                                      sends the audio to the pipe: the values are accepted and
#                                                      reported, but they do not change the audio.
#
#   POST plugins/Lyphile/vlclua/tc        player=<mac>&bits=<16|24>&rate=<44100|48000|96000>   the PCM settings of the player
#                                                      (prefs tc_bits and tc_rate, read by Bin/vlc-Player-lua when it starts;
#                                                      stereo always). Refused while VLC is running: they apply to the next
#                                                      track. Also in "rcstatus" as "tc".
#
# Every answer is JSON, in the same layout as the oldrc version: { ok => true|false, error => "...", ... }.
#
# The HTTP interface does not tell which audio track is selected. The one last chosen through this
# page is remembered for the run in progress (a run is told by its pipe <mac>.fifo, which Bin/vlc-Player-lua
# creates at each start); before any choice it is the first audio track, which VLC plays by default.
#
# A switch of audio track or chapter is also written to the log of the run in progress,
# <player folder>/vlc-transcode-<mac>.log, as:   Command: atrack 2 -> 2 - Stereo
#
# Events of Lyrion's own player that are passed on to VLC's HTTP interface of that player (when it
# answers):
#   playlist pause 1   -> pl_forcepause
#   playlist pause 0   -> pl_forceresume
#   playlist stop      -> pl_stop (and a signal to Bin/vlc-Player-lua when VLC does not stop, see _stop)

use strict;
use warnings;

use HTTP::Status qw(RC_OK);
use File::Basename qw(dirname);
use JSON::XS;
use LWP::UserAgent;
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::HTTP;
use Slim::Web::Pages;

my $log   = logger('plugin.lyphile');
my $prefs = preferences('plugin.lyphile');

# Same folder and name as in Bin/vlc-Player-lua: <dir>/<mac with dashes>/...
my $PLAYER_DIR = '/config/logs/lyphile/remote_players';

# { <mac> => { run => <run id>, id => <audio track id> } }: the audio track chosen on the page
my %chosen;

my %ENDPOINT = (
	rcstatus  => \&_rcstatus,
	transport => \&_transport,
	atrack    => \&_atrack,
	chapter   => \&_chapter,
	eq        => \&_eq,
	tc        => \&_tc,
);

sub init {
	Slim::Control::Request::subscribe(\&_onPlaylist, [['playlist'], ['pause', 'stop']]);

	foreach my $name (keys %ENDPOINT) {
		my $handler = $ENDPOINT{$name};

		Slim::Web::Pages->addPageFunction("plugins/Lyphile/vlclua/$name", sub {
			my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
			_send_json($httpClient, $httpResponse, $handler->($params));
		});
	}
}

sub shutdown {
	Slim::Control::Request::unsubscribe(\&_onPlaylist);
}

# "playlist pause <0|1>" and "playlist stop" of a player, passed on to its VLC
sub _onPlaylist {
	my $request = shift;

	my $client = $request->client or return;
	my $what   = $request->getRequest(1) or return;
	my $vlc    = _vlc($client->id) or return;

	# only a player that plays through vlc-Player-lua has an HTTP interface listening: no answer = nothing to do
	my $status = _status($vlc) or return;

	if ($what eq 'stop') {
		_stop($vlc);
		$log->info('vlc (lua): stop sent to ' . $client->id);
	}
	elsif ($what eq 'pause') {
		my $paused = $request->getRequest(2);
		$paused = $client->isPaused ? 1 : 0 unless defined $paused;

		my $state = $status->{state} // '';
		if ($paused && $state eq 'playing') {
			_command($vlc, 'pl_forcepause');
			$log->info('vlc (lua): pause sent to ' . $client->id);
		}
		elsif (!$paused && $state eq 'paused') {
			_command($vlc, 'pl_forceresume');
			$log->info('vlc (lua): resume sent to ' . $client->id);
		}
	}
}

sub _send_json {
	my ($httpClient, $httpResponse, $data) = @_;

	my $json = encode_json($data);
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	$httpResponse->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $httpResponse, \$json, undef, undef);
}

# A MAC address in lower case with colons, or undef for anything else
sub _mac {
	my $mac = lc(shift // '');
	return $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/ ? $mac : undef;
}

# How to reach the VLC of a player: { mac, base, auth } or undef (unknown player, no port or password)
sub _vlc {
	my $mac = _mac(shift) or return;

	my $client = Slim::Player::Client::getClient($mac) or return;
	my $port   = Plugins::Lyphile::Plugin::portOf($client, 'vlc');
	my $pw     = $prefs->client($client)->get('vlc_http_password');
	return unless $port && $port =~ /^\d+$/ && defined $pw && length $pw;

	return {
		mac  => $mac,
		base => "http://127.0.0.1:$port/requests",
		auth => 'Basic ' . encode_base64(":$pw", ''),
	};
}

my $ua;

# GET <base>/<path> and the decoded JSON, or undef when VLC does not answer
sub _get {
	my ($vlc, $path) = @_;

	$ua ||= LWP::UserAgent->new(timeout => 2, agent => 'Lyphile');
	my $res = $ua->get("$vlc->{base}/$path", Authorization => $vlc->{auth});
	return unless $res->is_success;

	return eval { decode_json($res->content) };
}

# status.json: undef when VLC's HTTP interface is not active
sub _status {
	return _get(shift, 'status.json');
}

# A command of the HTTP interface, e.g. ("chapter", 3): the status it answers with, or undef.
# Only plain words and numbers are ever sent (the callers check what they pass).
sub _command {
	my ($vlc, $command, $val) = @_;

	my $query = "command=$command";
	$query .= '&val=' . uri_escape($val) if defined $val;

	return _get($vlc, "status.json?$query");
}

# Stop VLC: pl_stop first. VLC then ends itself (--play-and-exit), but it ignores a stop while its output
# is blocked (after a chapter jump, for example), so when its HTTP interface still answers after 1 s the
# script that started it (Bin/vlc-Player-lua, pid in <player folder>/<mac>.pid) gets a TERM, which ends
# VLC and ffmpeg and cleans up.
sub _stop {
	my $vlc = shift;

	_command($vlc, 'pl_stop');

	for my $try (1 .. 5) {
		select(undef, undef, undef, 0.2);
		return unless _status($vlc);
	}

	(my $dir = $vlc->{mac}) =~ tr/:/-/;
	open(my $fh, '<', "$PLAYER_DIR/$dir/$dir.pid") or return;
	my ($pid) = (<$fh> // '') =~ /^(\d+)/;
	close $fh;
	return unless $pid;

	# only a process that is that script
	open(my $cmd, '<', "/proc/$pid/cmdline") or return;
	my $line = <$cmd> // '';
	close $cmd;
	return unless $line =~ /vlc-Player-lua/;

	kill 'TERM', $pid;
	$log->info("vlc (lua): VLC ignored the stop, vlc-Player-lua ($pid) ended for $vlc->{mac}");

	# the HTTP interface goes away with VLC
	for my $try (1 .. 10) {
		select(undef, undef, undef, 0.2);
		return unless _status($vlc);
	}
}

# The equalizer of VLC as the page shows it: { enabled, preamp, bands => [ 10 values in dB ] }, from the
# "equalizer" part of status.json (flat while VLC reports none). VLC does not report whether the equalizer is on: that is what the page
# last asked for in this run.
my %eq_on;        # { <mac> => { run => <run id>, on => 0|1 } }
my %eq_primed;    # { <mac> => <run id> }: the bands of this run were all written once, in order

sub _eq_state {
	my ($mac, $status) = @_;

	# VLC reports the equalizer (as an empty list) only once it was switched on: flat until then
	my $eq = $status->{equalizer};
	$eq = {} unless ref $eq eq 'HASH';

	my @bands = (0) x 10;
	foreach my $key (keys %{ $eq->{bands} || {} }) {
		$bands[$1] = $eq->{bands}{$key} + 0 if $key =~ /(\d+)/ && $1 < 10;
	}

	my $on = $eq_on{$mac};
	return {
		enabled => ($on && $on->{run} eq _run_id($mac) && $on->{on}) ? \1 : \0,
		preamp  => ($eq->{preamp} // 0) + 0,
		bands   => \@bands,
	};
}

# Equalizer of the page: one of  eq=on|off,  band=<0-9>&value=<dB>,  gain=<dB>,  reset=1. Values are plain
# numbers from -20 to 20 (what VLC takes); nothing else is ever sent to VLC.
sub _eq {
	my $params = shift;

	my $vlc = _vlc($params->{player}) or return { ok => \0, error => 'unknown player' };
	_status($vlc) or return { ok => \0, error => 'HTTP interface not active' };

	my $db = qr/^-?(?:\d{1,2})(?:\.\d)?$/;
	my $ok_db = sub { my $v = shift; defined $v && $v =~ $db && $v >= -20 && $v <= 20 };
	my @queries;

	if (defined $params->{eq}) {
		return { ok => \0, error => 'bad eq' } unless $params->{eq} eq 'on' || $params->{eq} eq 'off';
		my $on = $params->{eq} eq 'on' ? 1 : 0;
		push @queries, "command=enableeq&val=$on";
		$eq_on{ $vlc->{mac} } = { run => _run_id($vlc->{mac}), on => $on };
	}
	elsif (defined $params->{band}) {
		return { ok => \0, error => 'bad band' }  unless $params->{band} =~ /^[0-9]$/;
		return { ok => \0, error => 'bad value' } unless $ok_db->($params->{value});

		# VLC keeps the bands as a list that a band is written into by position: until all ten were written once, in
		# order, a single band lands in the wrong place. The first change of a run writes the ten current values first.
		my $run = _run_id($vlc->{mac});
		if (($eq_primed{ $vlc->{mac} } // '') ne $run) {
			my $state = _eq_state($vlc->{mac}, _status($vlc) || {});
			my @now = $state ? @{ $state->{bands} } : (0) x 10;
			push @queries, map { "command=equalizer&band=$_&val=$now[$_]" } 0 .. 9;
			$eq_primed{ $vlc->{mac} } = $run;
		}
		push @queries, "command=equalizer&band=$params->{band}&val=" . ($params->{value} + 0);
	}
	elsif (defined $params->{gain}) {
		return { ok => \0, error => 'bad gain' } unless $ok_db->($params->{gain});
		push @queries, 'command=preamp&val=' . ($params->{gain} + 0);
	}
	elsif ($params->{reset}) {
		push @queries, map { "command=equalizer&band=$_&val=0" } 0 .. 9;
		push @queries, 'command=preamp&val=0';
		$eq_primed{ $vlc->{mac} } = _run_id($vlc->{mac});
	}
	else {
		return { ok => \0, error => 'nothing to do' };
	}

	foreach my $query (@queries) {
		_get($vlc, "status.json?$query") or return { ok => \0, error => 'HTTP interface not active' };
	}

	my $status = _status($vlc);
	return { ok => \1, eq => ($status ? _eq_state($vlc->{mac}, $status) : undef) };
}


# PCM settings between VLC and ffmpeg: { bits => 16|24, rate => 44100|48000|96000 }, defaults 16 and 48000
sub _tc_state {
	my $mac = lc(shift // '');

	my $client = Slim::Player::Client::getClient($mac) or return { bits => 16, rate => 48000 };
	my $cprefs = $prefs->client($client);

	my $bits = $cprefs->get('tc_bits') // 16;
	my $rate = $cprefs->get('tc_rate') // 48000;
	return { bits => ($bits == 24 ? 24 : 16) + 0, rate => ({ 44100 => 1, 48000 => 1, 96000 => 1 }->{$rate} ? $rate : 48000) + 0 };
}

# Save the PCM settings. Only the listed values are accepted. They are read when a track starts, so a change while
# VLC is running (its HTTP interface answers) is refused.
sub _tc {
	my $params = shift;

	my $mac = lc($params->{player} // '');
	return { ok => \0, error => 'unknown player' } unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	my $client = Slim::Player::Client::getClient($mac) or return { ok => \0, error => 'unknown player' };

	return { ok => \0, error => 'bad bits' } if defined $params->{bits} && $params->{bits} !~ /^(16|24)$/;
	return { ok => \0, error => 'bad rate' } if defined $params->{rate} && $params->{rate} !~ /^(44100|48000|96000)$/;

	return { ok => \0, error => 'playing' } if do { my $v = _vlc($mac); $v && _status($v) ? 1 : 0 };

	my $cprefs = $prefs->client($client);
	$cprefs->set('tc_bits', $params->{bits} + 0) if defined $params->{bits};
	$cprefs->set('tc_rate', $params->{rate} + 0) if defined $params->{rate};

	return { ok => \1, tc => _tc_state($mac) };
}

# Identifies the run of vlc-Player-lua in progress: device and inode of the pipe it creates at each start
sub _run_id {
	my $mac = shift;

	(my $dir = $mac) =~ tr/:/-/;
	my @st = stat("$PLAYER_DIR/$dir/$dir.fifo") or return '';
	return "$st[0]-$st[1]";
}

# The streams of type Audio out of status.json, in the order of their numbers: [ { id, info => {...} } ].
# id is what "audio_track" takes: the "Original ID" of the stream when VLC reports one (a DVD: 48512, 48513,
# ... which are not the stream numbers), else the number of the stream ("Stream 2": mkv). A wrong id would
# switch the audio off, and VLC would then run through the title with no audio going to the pipe.
sub _audio {
	my $status = shift;

	my $cat = $status->{information} && $status->{information}{category} or return ();
	my @audio;

	foreach my $key (keys %$cat) {
		next unless $key =~ /^Stream (\d+)$/ && ref $cat->{$key} eq 'HASH' && ($cat->{$key}{Type} // '') eq 'Audio';
		my ($number, $info) = ($1 + 0, $cat->{$key});
		my $original = $info->{Original_ID};
		push @audio, { id => (defined $original && $original =~ /^\d+$/) ? $original + 0 : $number, number => $number, info => $info };
	}

	return sort { $a->{number} <=> $b->{number} } @audio;
}

# The id of the audio track that plays: the one chosen on the page for this run, else the one VLC shows as
# decoding when it is the only one, else the first
sub _selected_id {
	my ($mac, @audio) = @_;

	my $c = $chosen{$mac};
	if ($c && $c->{run} eq _run_id($mac) && grep { $_->{id} == $c->{id} } @audio) {
		return $c->{id};
	}

	my @decoding = grep { defined $_->{info}{Decoded_channels} } @audio;
	return $decoding[0]{id} if @decoding == 1;

	return @audio ? $audio[0]{id} : undef;
}

# The text of a stream: the fields that are there of Codec, Description, Language, Sample rate, channels, bitrate
sub _stream_text {
	my $info = shift;

	return join(' - ', grep { defined && length } (
		$info->{Codec}, $info->{Description}, $info->{Language}, $info->{Sample_rate} // $info->{Decoded_sample_rate}, $info->{Decoded_channels}, $info->{Decoded_Bitrate},
	));
}

# The audio streams of the player page: [ { id, text, selected } ]
sub _audio_streams {
	my ($mac, $status) = @_;

	my @audio = _audio($status);
	my $sel   = _selected_id($mac, @audio);

	return map {
		{ id => $_->{id}, text => (_stream_text($_->{info}) || 'Audio ' . $_->{id}), selected => (defined $sel && $_->{id} == $sel) ? \1 : \0 }
	} @audio;
}

# The chapters of the player page: [ { id, text, selected } ]. id is VLC's chapter number (from 0),
# text the number as people count them (from 1).
sub _chapters {
	my ($status, $starts) = @_;

	my $info = $status->{information} or return ();
	my $list = $info->{chapters};
	return () unless ref $list eq 'ARRAY' && @$list;

	my $current = $info->{chapter};

	# VLC does not follow the tracks of an embedded cuesheet: the current one is the last that started
	if ($starts && @$starts == @$list && defined $status->{time}) {
		$current = 0;
		for my $i (0 .. $#$starts) { $current = $i if $starts->[$i] <= $status->{time} + 0.5 }
	}

	my @ids = grep { /^\d+$/ } @$list;
	@ids = @ids[0 .. 998] if @ids > 999;

	return map { { id => $_ + 0, text => $_ + 1, selected => (defined $current && $_ == $current) ? \1 : \0 } } @ids;
}

# The start times (seconds) of the tracks of the cuesheet embedded in a FLAC file, or () when the file is not a
# FLAC or has no cuesheet. The cuesheet is either the text of the CUESHEET tag (Vorbis comment: "TRACK nn AUDIO",
# "INDEX 01 mm:ss:ff", 75 frames to the second) or the binary CUESHEET metadata block. VLC shows those tracks
# as chapters but does not move to the next chapter while the file plays, so the page works the current chapter
# out from the time and these starts. The result is kept per file and modification time.
my %cue_cache;

sub _flac_cue_starts {
	my $file = shift;

	my @st = stat($file) or return;
	my $key = "$file|$st[9]|$st[7]";
	return @{ $cue_cache{$key} } if $cue_cache{$key};

	%cue_cache = () if keys %cue_cache > 20;
	$cue_cache{$key} = [];

	open(my $fh, '<:raw', $file) or return;
	my $magic = '';
	read($fh, $magic, 4) == 4 && $magic eq 'fLaC' or return;

	my ($rate, @text, @block);
	while (1) {
		read($fh, my $hdr, 4) == 4 or last;
		my ($flags, $len) = unpack('C a3', $hdr);
		$len = unpack('N', "\0" . $len);
		my $type = $flags & 0x7f;

		# small blocks are read, the others (padding, pictures) skipped without reading
		if (($type == 0 || $type == 4 || $type == 5) && $len < 4_000_000) {
			read($fh, my $body, $len) == $len or last;

			if ($type == 0 && $len >= 18) {
				$rate = unpack('N', substr($body, 10, 4)) >> 12;     # 20 bits: sample rate
			}
			elsif ($type == 4) {
				# Vorbis comment: vendor, then count comments of (length, "NAME=value"), little endian
				my $pos = 4 + unpack('V', substr($body, 0, 4));
				my $n   = $pos + 4 <= $len ? unpack('V', substr($body, $pos, 4)) : 0;
				$pos += 4;
				for (1 .. $n) {
					last if $pos + 4 > $len;
					my $cl = unpack('V', substr($body, $pos, 4));
					$pos += 4;
					last if $pos + $cl > $len;
					my $comment = substr($body, $pos, $cl);
					$pos += $cl;
					next unless $comment =~ /^cuesheet=(.*)$/is;
					for my $line (split /\r?\n/, $1) {
						push @text, $1 * 60 + $2 + $3 / 75 if $line =~ /^\s*INDEX\s+01\s+(\d+):(\d+):(\d+)/;
					}
				}
			}
			elsif ($type == 5 && $rate && $len >= 396) {
				my $count = unpack('C', substr($body, 395, 1));
				my $pos   = 396;
				for (1 .. $count) {
					last if $pos + 36 > $len;
					my ($hi, $lo) = unpack('N N', substr($body, $pos, 8));
					my $number    = unpack('C', substr($body, $pos + 8, 1));
					my $indices   = unpack('C', substr($body, $pos + 35, 1));
					push @block, ($hi * 4294967296 + $lo) / $rate if $number != 170 && $number != 255;
					$pos += 36 + 12 * $indices;
				}
			}
		}
		else {
			seek($fh, $len, 1) or last;
		}

		last if $flags & 0x80;
	}
	close $fh;

	my @starts = @text ? @text : @block;
	$cue_cache{$key} = \@starts;
	return @starts;
}

# The path of a local file out of the input URI of VLC (file:///...), or undef
sub _local_file {
	my $uri = shift // '';

	return unless $uri =~ m{^file://(/.*)$};
	my $path = $1;
	$path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
	return -f $path ? $path : undef;
}

# The lines of the statistics of the page, in the layout of the oldrc [Incoming] lines
sub _stats_lines {
	my $status = shift;

	my $s = $status->{stats} or return ();
	return () unless ref $s eq 'HASH';

	my $kib = sub { defined $_[0] ? sprintf('%d KiB', $_[0] / 1024) : '-' };
	my $kbs = sub { defined $_[0] ? sprintf('%.2f kb/s', $_[0] * 8000) : '-' };
	my $num = sub { defined $_[0] ? $_[0] + 0 : '-' };

	return (
		'input bytes read : ' . $kib->($s->{readbytes}),
		'input bitrate    : ' . $kbs->($s->{inputbitrate}),
		'demux bytes read : ' . $kib->($s->{demuxreadbytes}),
		'demux bitrate    : ' . $kbs->($s->{demuxbitrate}),
		'demux corrupted  : ' . $num->($s->{demuxcorrupted}),
		'discontinuities  : ' . $num->($s->{demuxdiscontinuity}),
	);
}

# The input: the URI of the item that plays now, from playlist.json
sub _input_of {
	my $vlc = shift;

	my $pl = _get($vlc, 'playlist.json') or return '';
	my @todo = ($pl);

	while (my $node = shift @todo) {
		next unless ref $node eq 'HASH';
		return $node->{uri} // '' if ($node->{current} // '') eq 'current' && defined $node->{uri};
		push @todo, @{ $node->{children} || [] };
	}

	return '';
}

# The track Lyrion shows for the player: the one at the playing position of its playlist, which is the library track
# when the song was played from the library (the track of the streaming song can be a temporary one, without artwork
# or title, for a DVD title), else the track of the streaming song.
sub _playing_track {
	my $client = shift or return;

	my $index = Slim::Player::Source::playingSongIndex($client);
	my $track = defined $index ? Slim::Player::Playlist::song($client, $index) : undef;

	if (!$track) {
		my $song = $client->playingSong;
		$track = $song ? $song->currentTrack : undef;
	}

	return $track;
}

# What the player is playing, from Lyrion's own track data (the player page and Lyrion show the
# same song): [ artist, album, title ], or () when Lyrion has no such song
sub _lyrion_track {
	my $mac = lc(shift // '');

	my $client = Slim::Player::Client::getClient($mac) or return;
	my $track  = _playing_track($client) or return;

	return ($track->artistName // '', $track->albumname // '', $track->title // '');
}

# The library track (in Lyrion's database) behind the URL of the track that plays, or undef. A track that is played
# from a URL that is not written the way the library has it (a DVD title: the library keeps "%20" for the spaces, the
# URL of the player has the plain spaces) is a temporary track without artwork; the library track has it.
sub _library_track {
	my $url = shift;
	return unless defined $url && length $url;

	my @candidates = ($url);
	(my $spaces = $url) =~ s/ /%20/g;
	push @candidates, $spaces if $spaces ne $url;
	(my $escaped = $url) =~ s{([^A-Za-z0-9/:?=&_.~()\[\]!\$',;@%+-])}{sprintf('%%%02X', ord($1))}ge;
	push @candidates, $escaped if $escaped ne $url && $escaped ne $spaces;

	foreach my $candidate (@candidates) {
		my $track = eval { Slim::Schema->rs('Track')->single({ url => $candidate }) }
			|| Slim::Schema->objectForUrl({ url => $candidate, create => 0, readTags => 0 });
		return $track if $track && $track->id && $track->id > 0;
	}

	return;
}

# The artwork of the song Lyrion plays on the player, as a path below the server root, or '': the cover id of the
# track in Lyrion's own artwork route, which is exact for that song (the "current" route is not). When the track that
# plays is a temporary one (negative id), the cover id is that of the library track with the same URL (see above), and
# only without one the temporary track's own (a placeholder). 250x250 at most, original proportions.
sub _lyrion_cover {
	my $mac = lc(shift // '');

	my $client = Slim::Player::Client::getClient($mac) or return '';
	my $track  = _playing_track($client) or return '';

	my $id = $track->can('coverid') ? $track->coverid : undef;

	if (!defined $id || !length $id || $id =~ /^-/) {
		my $library = _library_track($track->url);
		my $found   = $library && $library->can('coverid') ? $library->coverid : undef;
		$found = $library->id if $library && (!defined $found || !length $found);    # Lyrion's route also takes a track id
		$id = $found if defined $found && length $found && $found !~ /^-/;
	}

	$id = $track->id if !defined $id || !length $id;

	# a cover id is a hash, a track id a number (negative for tracks that are not in the library, such as a DVD title)
	return '' unless defined $id && ($id =~ /^[0-9a-zA-Z]{1,64}$/ || $id =~ /^-[0-9]{1,30}$/);

	return "music/$id/cover_250x250_o.jpg";
}

# Lines appended to the log of the run in progress (see the header). Nothing is written when there
# is no such file: it only exists while Bin/vlc-Player-lua runs.
sub _runLog {
	my ($mac, @lines) = @_;

	(my $dir = $mac) =~ tr/:/-/;
	my $file = "$PLAYER_DIR/$dir/vlc-transcode-$dir.log";
	return unless -f $file;

	open(my $fh, '>>', $file) or return;
	print $fh map { "$_\n" } @lines;
	close $fh;
}

# Switch the audio track. The id must be one of the audio streams VLC reports (a plain number). The
# status is read again, up to 5 times 0.2 s apart, until it shows the stream as decoding.
sub _atrack {
	my $params = shift;

	my $vlc = _vlc($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad audio track' } unless defined $id && $id =~ /^\d{1,9}$/;
	$id += 0;

	my $status = _status($vlc) or return { ok => \0, error => 'HTTP interface not active' };

	my ($stream) = grep { $_->{id} == $id } _audio($status);
	return { ok => \0, error => 'unknown audio track' } unless $stream;

	_command($vlc, 'audio_track', $id) or return { ok => \0, error => 'HTTP interface not active' };
	$chosen{ $vlc->{mac} } = { run => _run_id($vlc->{mac}), id => $id };

	# VLC does not report which audio track is selected: the switch counts as confirmed when VLC accepted the
	# command and still answers (the stream reads as decoding once VLC has started it, which depends on its output)
	my $confirmed = 1;
	for my $try (1 .. 5) {
		select(undef, undef, undef, 0.2);
		$status = _status($vlc) or do { $confirmed = 0; last };
		my ($now) = grep { $_->{id} == $id } _audio($status);
		last if $now && defined $now->{info}{Decoded_channels};
	}

	my @streams = $status ? _audio_streams($vlc->{mac}, $status) : ();
	_runLog($vlc->{mac}, "  Command: atrack $id -> $id - " . _stream_text($stream->{info})
		. ($confirmed ? '' : ' (VLC stopped answering)'));

	return { ok => \1, confirmed => $confirmed ? \1 : \0, streams => \@streams };
}

# Switch the chapter: the id is a plain number inside the chapters VLC reports, and the status is read
# again until it shows the chapter asked for (5 times, 0.2 s apart).
sub _chapter {
	my $params = shift;

	my $vlc = _vlc($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad chapter' } unless defined $id && $id =~ /^\d{1,3}$/;
	$id += 0;

	my $status = _status($vlc) or return { ok => \0, error => 'HTTP interface not active' };
	return { ok => \0, error => 'unknown chapter' } unless grep { $_->{id} == $id } _chapters($status);

	_command($vlc, 'chapter', $id) or return { ok => \0, error => 'HTTP interface not active' };

	my $confirmed = 0;
	for my $try (1 .. 5) {
		select(undef, undef, undef, 0.2);
		$status = _status($vlc) or last;
		my $current = $status->{information} && $status->{information}{chapter};
		if (defined $current && $current == $id) { $confirmed = 1; last }
	}

	my @chapters = $status ? _chapters($status) : ();
	my $count    = scalar @chapters;
	_runLog($vlc->{mac}, "  Command: chapter $id -> Currently playing chapter " . ($status ? $status->{information}{chapter} : '?') . "/$count"
		. ($confirmed ? '' : ' (VLC did not switch to that chapter)'));

	return { ok => \1, confirmed => $confirmed ? \1 : \0, chapters => \@chapters };
}

# The pause and stop buttons of the page act on Lyrion's player, as the buttons of Lyrion do. Its
# "playlist pause" and "playlist stop" events (see _onPlaylist) then reach VLC, so that Lyrion and
# VLC stay one: stopping VLC alone would make Lyrion see an end of stream.
sub _transport {
	my $params = shift;

	my $mac = _mac($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $client = Slim::Player::Client::getClient($mac) or return { ok => \0, error => 'unknown player' };

	my $action = $params->{action} // '';
	return { ok => \0, error => 'bad action' } unless $action eq 'pause' || $action eq 'stop';

	$client->execute([$action]);
	$log->info("vlc page (lua): $action of $mac");

	return { ok => \1 };
}

# Active = the HTTP interface answers with the player's password
sub _rcstatus {
	my $params = shift;

	my $mac = _mac($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $vlc = _vlc($mac)              or return { ok => \0, error => 'unknown player' };

	my $status = _status($vlc);
	unless ($status) {
		delete $chosen{$mac};
		return { ok => \1, active => \0, input => '', streams => [], chapters => [], stats => [], now => {}, tc => _tc_state($mac) };
	}

	my $state = { playing => 'playing', paused => 'paused', stopped => 'stopped' }->{ $status->{state} // '' } // '';
	my $meta  = ($status->{information} && $status->{information}{category} && $status->{information}{category}{meta}) || {};

	my %now = (
		state  => $state,
		time   => defined $status->{time}   ? $status->{time} + 0   : undef,
		length => defined $status->{length} ? $status->{length} + 0 : undef,
	);

	# artist, album and title are Lyrion's; without them the title of the item in VLC is used
	my ($artist, $album, $title) = eval { _lyrion_track($mac) };
	@now{qw(artist album title)} = (defined $title && length $title) ? ($artist, $album, $title) : ('', '', $meta->{title} // $meta->{filename} // '');
	$now{cover} = eval { _lyrion_cover($mac) } // '';

	my $input = _input_of($vlc);

	return {
		ok       => \1,
		active   => \1,
		input    => $input,
		streams  => [ _audio_streams($mac, $status) ],
		chapters => [ _chapters($status, [ _flac_cue_starts(_local_file($input) // '') ]) ],
		stats    => [ _stats_lines($status) ],
		now      => \%now,
		eq       => _eq_state($mac, $status),
		tc       => _tc_state($mac),
	};
}

1;
