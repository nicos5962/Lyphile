package Plugins::Lyphile::FFmpeg::Control;

# Endpoints of the FFmpeg player page, the counterpart of Plugins::Lyphile::VLC::Control and ::ControlLua for a player
# whose helper is Bin/FFmpeg-Player. ffmpeg has no remote interface to ask: what the page shows comes from
#   - Lyrion itself: the state (play, pause), the position, the track (artist, album, title, artwork), as for VLC;
#   - ffmpeg's report, <player folder>/ffmpeg-report.log (the input dump: audio streams, chapters, duration; and the
#     "Map input stream N to output stream 0" lines ffmpeg prints each time a switch of audio stream was applied);
#   - ffmpeg's progress file, <player folder>/progress.log (output time, size, bitrate, speed: the statistics).
# Live control goes to the filter graph of the running ffmpeg through its azmq filter (zmqsend, the player's zmq_port).
#
#   POST plugins/Lyphile/ffmpeg/rcstatus   player=<mac>   active (ffmpeg runs for the player), input, streams
#                                                      [{ id, text, selected }], chapters [{ id, text, selected }],
#                                                      stats [lines], now { state, time, length, artist, album, title,
#                                                      cover }, eq { enabled, preamp, bands }, tc { bits, rate }
#   POST plugins/Lyphile/ffmpeg/atrack     player=<mac>&id=<audio stream, from 0>   astreamselect@sel map <id>; the
#                                                      answer is confirmed when the report shows the map line
#   POST plugins/Lyphile/ffmpeg/chapter    player=<mac>&id=<chapter, from 0>   Lyrion seeks the player to the start of
#                                                      the chapter (it restarts the stream there: the rule has -s)
#   POST plugins/Lyphile/ffmpeg/transport  player=<mac>&action=<pause|stop>   pause (toggle) or stop the Lyrion player
#   POST plugins/Lyphile/ffmpeg/eq         player=<mac>&(eq=on|off | band=<0-9>&value=<dB> | gain=<dB> | reset=1)
#                                                      volume@pre and equalizer@eq0..9 of the filter graph; saved in the
#                                                      prefs eq_enabled, eq_gain, eq_bands, which Bin/FFmpeg-Player
#                                                      reads at the next start
#   POST plugins/Lyphile/ffmpeg/tc         player=<mac>&bits=<16|24>&rate=<44100|48000|96000>   PCM settings (prefs tc_bits,
#                                                      tc_rate); refused while ffmpeg runs
#
# Every answer is JSON: { ok => true|false, error => "...", ... }, as for the VLC pages.

use strict;
use warnings;

use HTTP::Status qw(RC_OK);
use File::Basename qw(dirname);
use IPC::Open2;
use JSON::XS;
use POSIX ();
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Web::HTTP;
use Slim::Web::Pages;

use Plugins::Lyphile::VLC::ControlLua;

my $log   = logger('plugin.lyphile');
my $prefs = preferences('plugin.lyphile');

# Same folder as in Bin/FFmpeg-Player: <dir>/<mac with dashes>/...
my $PLAYER_DIR = '/config/logs/lyphile/remote_players';

my $ZMQ_TIMEOUT = 2;      # s, hard limit of one zmqsend call
my $zmqBin;               # path of zmqsend, once found

my %ENDPOINT = (
	rcstatus  => \&_rcstatus,
	transport => \&_transport,
	atrack    => \&_atrack,
	chapter   => \&_chapter,
	eq        => \&_eq,
	tc        => \&_tc,
);

sub init {
	foreach my $name (keys %ENDPOINT) {
		my $handler = $ENDPOINT{$name};

		Slim::Web::Pages->addPageFunction("plugins/Lyphile/ffmpeg/$name", sub {
			my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
			_send_json($httpClient, $httpResponse, $handler->($params));
		});
	}
}

sub shutdown { }

sub _send_json {
	my ($httpClient, $httpResponse, $data) = @_;

	my $json = encode_json($data);
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	$httpResponse->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $httpResponse, \$json, undef, undef);
}

# ($client, $mac with colons) of a player given as in the request, or ()
sub _player {
	my $mac = lc(shift // '');
	return unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	my $client = Slim::Player::Client::getClient($mac) or return;
	return ($client, $mac);
}

sub _file {
	my ($mac, $name) = @_;
	(my $dir = $mac) =~ tr/:/-/;
	return "$PLAYER_DIR/$dir/$name";
}

# ------------------------------------------------------------------------------------------------------------------
# ffmpeg's report: the input dump, parsed again whenever the file changed
# ------------------------------------------------------------------------------------------------------------------
my %report;    # { <mac> => { sig => "size-mtime", data => {...} } }

# The seek that is waiting for the next run of Bin/FFmpeg-Player: { start => seconds, old => the report of the run
# that was playing, at => time of the request }, and the offset of the run that came of it (the position Lyrion
# shows counts from the start of that run).
my (%pending, %offset);

# { started, format, from, duration, chapters => [ { start, end } ], audio => [ { id, language, props } ], ready,
#   current } of the report of the last run of a player
sub _report {
	my $mac = shift;

	my $file = _file($mac, 'ffmpeg-report.log');
	my @st   = stat($file) or return;
	my $list = _file($mac, 'audio-streams.txt');
	my @ls   = stat($list);
	my $sig  = "$st[7]-$st[9]-" . (@ls ? "$ls[7]-$ls[9]" : '');

	my $cached = $report{$mac};
	return $cached->{data} if $cached && $cached->{sig} eq $sig;

	open(my $fh, '<', $file) or return;
	my %d = (chapters => [], audio => [], ready => 0, current => undef);
	my $in_input = 0;

	while (my $line = <$fh>) {
		$line =~ s/[\r\n]+\z//;
		next unless $line =~ /\S/;

		# the "Input #" dump is made of indented lines; the first non-indented line ends it
		$in_input = 0 if $in_input && $line !~ /^\s/;

		if ($line =~ /^ffmpeg started on (.*)/) {
			%d = (chapters => [], audio => [], ready => 0, current => undef, started => $1);
			$in_input = 0;
		}
		elsif ($line =~ /^Input #\d+,\s*(.+?),\s*from\s+'(.*)'/ && !defined $d{from}) {
			@d{qw(format from)} = ($1, $2);
			$in_input = 1;
		}
		elsif ($in_input) {
			if ($line =~ /^\s*Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/) {
				$d{duration} = $1 * 3600 + $2 * 60 + $3;
			}
			elsif ($line =~ /^\s{4}title\s*:\s*(.+?)\s*$/ && !defined $d{title}) {
				$d{title} = $1;
			}
			elsif ($line =~ /^\s*Chapter #[^:]+:[^:]+:\s*start\s+([\d.]+),\s*end\s+([\d.]+)/) {
				push @{ $d{chapters} }, { start => $1 + 0, end => $2 + 0 };
			}
			elsif ($line =~ /^\s*Stream #\d+:(\d+)(?:\[([^\]]+)\])?(?:\(([^)]+)\))?:\s*Audio:\s*(.*)$/) {
				push @{ $d{audio} }, { index => $1 + 0, language => $3, props => $4 };
			}
		}
		elsif ($line =~ /^Stream mapping:/) {
			$d{ready} = 1;
			$d{current} //= 0 if @{ $d{audio} };
		}
		elsif ($line =~ /^\[astreamselect\@sel @ [^\]]+\] Map input stream (\d+) to output stream 0/) {
			$d{current} = $1 + 0;
		}
	}
	close $fh;

	# only the audio streams Bin/FFmpeg-Player put into the filter graph can be played: their position in that list is
	# the number astreamselect takes (and prints in "Map input stream N")
	my @graph;
	if (open(my $lf, '<', $list)) {
		@graph = split ' ', (<$lf> // '');
		close $lf;
	}
	if (@graph) {
		my %in = map { $_ => 1 } @graph;
		@{ $d{audio} } = grep { $in{ $_->{index} } } @{ $d{audio} };
	}
	for my $i (0 .. $#{ $d{audio} }) { $d{audio}[$i]{id} = $i }

	$report{$mac} = { sig => $sig, data => \%d };
	return \%d;
}

# ffmpeg's -progress file: the last complete block as { key => value }
sub _progress {
	my $mac = shift;

	my $file = _file($mac, 'progress.log');
	open(my $fh, '<', $file) or return {};
	my $size = -s $fh;
	seek($fh, $size > 4096 ? $size - 4096 : 0, 0);
	local $/;
	my $text = <$fh> // '';
	close $fh;

	my ($last) = $text =~ /((?:[a-z_0-9]+=[^\n]*\n)+?progress=\w+\n)\z/s;
	return {} unless defined $last;

	return { map { /^([a-z_0-9]+)=(.*)$/ ? ($1 => $2) : () } split /\n/, $last };
}

# ------------------------------------------------------------------------------------------------------------------
# The parts of the answer
# ------------------------------------------------------------------------------------------------------------------
my %LANG = (
	eng => 'English', fre => 'French', fra => 'French', ger => 'German', deu => 'German', spa => 'Spanish',
	ita => 'Italian', por => 'Portuguese', dut => 'Dutch', nld => 'Dutch', swe => 'Swedish', nor => 'Norwegian',
	dan => 'Danish', fin => 'Finnish', pol => 'Polish', cze => 'Czech', ces => 'Czech', hun => 'Hungarian',
	rus => 'Russian', jpn => 'Japanese', chi => 'Chinese', zho => 'Chinese', kor => 'Korean',
);

# "ac3, 48000 Hz, 5.1(side), fltp, 448 kb/s, start 0.016000" -> "AC3 - English - 48000 Hz - 5.1 - 448 kb/s"
sub _audio_text {
	my $a = shift;

	my @p = map { s/^\s+|\s+$//gr } split /,/, ($a->{props} // '');
	my $codec = uc(($p[0] // 'audio') =~ s/\s*\(.*//r);
	my ($hz)   = map { /^(\d+)\s*Hz$/ ? "$1 Hz" : () } @p;
	my ($kbps) = map { /^(\d+\s*kb\/s)$/ ? $1 : () } @p;
	my ($layout) = map { /^(mono|stereo|\d\.\d(?:\([a-z]+\))?|\d+ channels)/ ? ($1 =~ s/\(.*\)//r) : () } @p;
	my $lang = $a->{language} ? ($LANG{lc $a->{language}} // uc $a->{language}) : '';

	return join(' - ', grep { defined && length } $codec, $lang, $hz, $layout, $kbps);
}

sub _streams {
	my $rep = shift;

	return map {
		{ id => $_->{id}, text => _audio_text($_), selected => (defined $rep->{current} && $rep->{current} == $_->{id}) ? \1 : \0 }
	} @{ $rep->{audio} || [] };
}

# chapters as the VLC pages have them: id from 0, text from 1; the current one is the last that started
sub _chapters {
	my ($rep, $time) = @_;

	my $list = $rep->{chapters} || [];
	return () unless @$list;

	my $current = 0;
	if (defined $time) {
		for my $i (0 .. $#$list) { $current = $i if $list->[$i]{start} <= $time + 0.5 }
	}

	return map { { id => $_, text => $_ + 1, selected => $_ == $current ? \1 : \0 } } 0 .. $#$list;
}

sub _stats_lines {
	my $p = shift;
	return () unless %$p;

	my $kib = sub { defined $_[0] && $_[0] =~ /^\d+$/ ? sprintf('%d KiB', $_[0] / 1024) : '-' };
	my $t   = sub { defined $_[0] && $_[0] =~ /^(\d+):(\d+):(\d+)/ ? sprintf('%d:%02d:%02d', $1, $2, $3) : '-' };
	my $s   = sub { my $v = shift; defined $v && length $v ? $v =~ s/^\s+//r : '-' };

	return (
		'output time   : ' . $t->($p->{out_time}),
		'output size   : ' . $kib->($p->{total_size}),
		'output bitrate: ' . $s->($p->{bitrate}),
		'speed         : ' . $s->($p->{speed}),
	);
}

# What Lyrion knows of the player: state, position, length
sub _lyrion_now {
	my ($client, $rep) = @_;

	my $mode  = eval { Slim::Player::Source::playmode($client) } // 'stop';
	my $state = $mode eq 'play' ? 'playing' : $mode eq 'pause' ? 'paused' : 'stopped';

	my $time   = eval { Slim::Player::Source::songTime($client) };
	my $song   = $client->playingSong;
	my $length = $song ? eval { $song->duration } : undef;
	$length = $rep->{duration} if !$length && $rep;

	return (
		state  => $state,
		time   => defined $time   ? int($time + 0)   : undef,
		length => defined $length ? int($length + 0) : undef,
	);
}

# Is ffmpeg running for the player: Lyrion plays (or paused) it, and the report of the run is complete
sub _running {
	my ($client, $mac) = @_;

	my $mode = eval { Slim::Player::Source::playmode($client) } // 'stop';
	return 0 unless $mode eq 'play' || $mode eq 'pause';

	my $rep = _report($mac);
	return $rep && $rep->{ready} ? 1 : 0;
}

# ------------------------------------------------------------------------------------------------------------------
# Equalizer state (prefs)
# ------------------------------------------------------------------------------------------------------------------
sub _eq_state {
	my $client = shift;

	my $cprefs = $prefs->client($client);
	my @bands  = split ' ', ($cprefs->get('eq_bands') // '');
	@bands = map { defined $bands[$_] && $bands[$_] =~ /^-?\d{1,2}(\.\d)?$/ ? $bands[$_] + 0 : 0 } 0 .. 9;

	return {
		enabled => $cprefs->get('eq_enabled') ? \1 : \0,
		preamp  => ($cprefs->get('eq_gain') // 0) + 0,
		bands   => \@bands,
	};
}

sub _rcstatus {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $tc = Plugins::Lyphile::VLC::ControlLua::_tc_state($mac);
	my $eq = _eq_state($client);

	unless (_running($client, $mac)) {
		return { ok => \1, active => \0, input => '', streams => [], chapters => [], stats => [], now => {}, tc => $tc, eq => $eq };
	}

	my $rep  = _report($mac);
	my %now  = _lyrion_now($client, $rep);

	# a run that began after a seek by chapter counts its time from the chapter
	if (my $p = $pending{$mac}) {
		if (($rep->{started} // '') ne $p->{old}) {
			$offset{$mac} = { run => $rep->{started} // '', start => $p->{start} };
			delete $pending{$mac};
		}
		elsif (time() - $p->{at} > 30) {
			delete $pending{$mac};
		}
	}
	if (my $o = $offset{$mac}) {
		if (($rep->{started} // '') eq $o->{run}) { $now{time} += $o->{start} if defined $now{time} }
		else { delete $offset{$mac} }
	}

	my ($artist, $album, $title) = eval { Plugins::Lyphile::VLC::ControlLua::_lyrion_track($mac) };
	my $name = $rep->{title};
	$name = (($rep->{from} // '') =~ m{([^/]+?)(?:\.[A-Za-z0-9]{2,4})?$})[0] // '' unless defined $name && length $name;
	@now{qw(artist album title)} = (defined $title && length $title) ? ($artist, $album, $title) : ('', '', $name);
	$now{cover} = eval { Plugins::Lyphile::VLC::ControlLua::_lyrion_cover($mac) } // '';

	return {
		ok       => \1,
		active   => \1,
		input    => $rep->{from} // '',
		streams  => [ _streams($rep) ],
		chapters => [ _chapters($rep, $now{time}) ],
		stats    => [ _stats_lines(_progress($mac)) ],
		now      => \%now,
		tc       => $tc,
		eq       => $eq,
	};
}

# ------------------------------------------------------------------------------------------------------------------
# zmqsend: one command to the filter graph of the running ffmpeg. No shell, hard timeout.
# Returns ($status, $message): (0, "Success") when applied, (undef, "reason") when it could not be sent.
# ------------------------------------------------------------------------------------------------------------------
sub _zmq_send {
	my ($client, $target, $command, $arg) = @_;

	my $endpoint = $prefs->client($client)->get('zmq_port');
	return (undef, 'no zmq endpoint') unless $endpoint && $endpoint =~ m{^tcp://127\.0\.0\.1:\d+$};

	$zmqBin ||= Slim::Utils::Misc::findbin('zmqsend');
	if (!$zmqBin) {
		my $found = qx(find /config/ -type f -name "zmqsend" 2>/dev/null | head -n 1);
		chomp $found if defined $found;
		$zmqBin = $found if $found;
	}
	return (undef, 'zmqsend not found') unless $zmqBin;

	local $SIG{PIPE} = 'IGNORE';
	my ($out, $in);
	my $pid = eval { open2($out, $in, 'timeout', $ZMQ_TIMEOUT, $zmqBin, '-b', $endpoint) };
	return (undef, 'cannot run zmqsend: ' . ($@ || $!)) unless $pid;

	print {$in} "$target $command $arg\n";
	close $in;
	my $reply = <$out>;
	close $out;
	waitpid($pid, 0);

	return (undef, 'no reply (ffmpeg not running?)') unless defined $reply;
	chomp $reply;
	return $reply =~ /^(-?\d+)\s*(.*)$/ ? ($1 + 0, $2) : (undef, $reply);
}

# ------------------------------------------------------------------------------------------------------------------
# Audio stream, chapter, transport
# ------------------------------------------------------------------------------------------------------------------
sub _atrack {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad audio stream' } unless defined $id && $id =~ /^\d{1,3}$/;
	$id += 0;

	return { ok => \0, error => 'ffmpeg not running' } unless _running($client, $mac);

	my $rep = _report($mac);
	return { ok => \0, error => 'unknown audio stream' } unless grep { $_->{id} == $id } @{ $rep->{audio} };
	return { ok => \0, error => 'one audio stream only' } if @{ $rep->{audio} } < 2;

	my ($status, $message) = _zmq_send($client, 'astreamselect@sel', 'map', $id);
	return { ok => \0, error => $message // 'zmqsend failed' } unless defined $status && $status == 0;

	# ffmpeg prints "Map input stream N to output stream 0" when it applied the command
	my $confirmed = 0;
	for my $try (1 .. 8) {
		select(undef, undef, undef, 0.15);
		$rep = _report($mac);
		if (defined $rep->{current} && $rep->{current} == $id) { $confirmed = 1; last }
	}

	$log->info("ffmpeg page: audio stream $id for $mac" . ($confirmed ? '' : ' (not confirmed by the report)'));

	return { ok => \1, confirmed => $confirmed ? \1 : \0, streams => [ _streams($rep) ] };
}

# A chapter: for a file Lyrion seeks the player to its start (it restarts the stream at that time: the rule has the
# start option). A DVD title it does not seek that way, so then the player's current song is played again, and
# Bin/FFmpeg-Player starts at the time it finds in the pref seek_start (written here, valid for 15 s).
sub _chapter {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $id = $params->{id};
	return { ok => \0, error => 'bad chapter' } unless defined $id && $id =~ /^\d{1,3}$/;

	return { ok => \0, error => 'ffmpeg not running' } unless _running($client, $mac);

	my $rep  = _report($mac);
	my $list = $rep->{chapters} || [];
	return { ok => \0, error => 'unknown chapter' } unless $id < @$list;

	my $start = int($list->[$id]{start} + 0.5);
	my $song  = $client->playingSong;
	my $can   = $song ? eval { $song->canDoSeek } : 0;
	my $url   = $song ? eval { $song->currentTrack->url } : '';

	# Lyrion's own seek restarts the transcoder at that time for a file; it does not for a DVD title (checked: the
	# stream starts again from the beginning), so only files are left to Lyrion
	if ($can && $can == 2 && ($url // '') =~ m{^file://}) {
		$client->execute(['time', $start]);
		$log->info("ffmpeg page: chapter $id (from $start s) for $mac, by Lyrion's seek");
	}
	else {
		my $index = eval { Slim::Player::Source::playingSongIndex($client) };
		return { ok => \0, error => 'no song to restart' } unless defined $index;

		$prefs->client($client)->set('seek_start', "$start\@" . time());
		$pending{$mac} = { start => $start, old => $rep->{started} // '', at => time() };
		$client->execute(['playlist', 'index', $index]);
		$log->info("ffmpeg page: chapter $id (from $start s) for $mac, by playing the song again");
	}

	return { ok => \1, confirmed => \1, chapters => [ _chapters($rep, $start) ] };
}

sub _transport {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };

	my $action = $params->{action} // '';
	return { ok => \0, error => 'bad action' } unless $action eq 'pause' || $action eq 'stop';

	$client->execute([$action]);
	$log->info("ffmpeg page: $action of $mac");

	return { ok => \1 };
}

# ------------------------------------------------------------------------------------------------------------------
# Equalizer: live through zmq while ffmpeg runs, always saved in the prefs for the next start
# ------------------------------------------------------------------------------------------------------------------
sub _eq {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };
	my $cprefs = $prefs->client($client);

	my $ok_db = sub { my $v = shift; defined $v && $v =~ /^-?\d{1,2}(?:\.\d)?$/ && $v >= -20 && $v <= 20 };
	my $db    = sub { sprintf('%g', $_[0] + 0) };

	my $state = _eq_state($client);
	my @bands = @{ $state->{bands} };
	my $gain  = $state->{preamp};
	my $on    = $state->{enabled} ? 1 : 0;

	my @commands;     # [ target, command, argument ] for the running ffmpeg
	my $live = _running($client, $mac);

	if (defined $params->{eq}) {
		return { ok => \0, error => 'bad eq' } unless $params->{eq} eq 'on' || $params->{eq} eq 'off';
		$on = $params->{eq} eq 'on' ? 1 : 0;
		# off = flat, without forgetting the values
		push @commands, [ 'volume@pre', 'volume', ($on ? $db->($gain) : '0') . 'dB' ];
		push @commands, [ "equalizer\@eq$_", 'gain', $on ? $db->($bands[$_]) : '0' ] for 0 .. 9;
	}
	elsif (defined $params->{band}) {
		return { ok => \0, error => 'bad band' }  unless $params->{band} =~ /^[0-9]$/;
		return { ok => \0, error => 'bad value' } unless $ok_db->($params->{value});
		$bands[ $params->{band} ] = $params->{value} + 0;
		push @commands, [ "equalizer\@eq$params->{band}", 'gain', $db->($params->{value}) ] if $on;
	}
	elsif (defined $params->{gain}) {
		return { ok => \0, error => 'bad gain' } unless $ok_db->($params->{gain});
		$gain = $params->{gain} + 0;
		push @commands, [ 'volume@pre', 'volume', $db->($gain) . 'dB' ] if $on;
	}
	elsif ($params->{reset}) {
		@bands = (0) x 10;
		$gain  = 0;
		push @commands, [ 'volume@pre', 'volume', '0dB' ];
		push @commands, [ "equalizer\@eq$_", 'gain', '0' ] for 0 .. 9;
	}
	else {
		return { ok => \0, error => 'nothing to do' };
	}

	# live first: nothing is saved when ffmpeg did not take it
	if ($live) {
		foreach my $c (@commands) {
			my ($status, $message) = _zmq_send($client, @$c);
			return { ok => \0, error => $message // 'zmqsend failed' } unless defined $status && $status == 0;
		}
	}

	$cprefs->set('eq_enabled', $on);
	$cprefs->set('eq_gain', $gain);
	$cprefs->set('eq_bands', join(' ', @bands));

	return { ok => \1, live => $live ? \1 : \0, eq => _eq_state($client) };
}

# ------------------------------------------------------------------------------------------------------------------
# PCM settings (prefs read by Bin/FFmpeg-Player at the start of a track)
# ------------------------------------------------------------------------------------------------------------------
sub _tc {
	my $params = shift;

	my ($client, $mac) = _player($params->{player}) or return { ok => \0, error => 'unknown player' };

	return { ok => \0, error => 'bad bits' } if defined $params->{bits} && $params->{bits} !~ /^(16|24)$/;
	return { ok => \0, error => 'bad rate' } if defined $params->{rate} && $params->{rate} !~ /^(44100|48000|96000)$/;

	return { ok => \0, error => 'playing' } if _running($client, $mac);

	my $cprefs = $prefs->client($client);
	$cprefs->set('tc_bits', $params->{bits} + 0) if defined $params->{bits};
	$cprefs->set('tc_rate', $params->{rate} + 0) if defined $params->{rate};

	return { ok => \1, tc => Plugins::Lyphile::VLC::ControlLua::_tc_state($mac) };
}

1;
