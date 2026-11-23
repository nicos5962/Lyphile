package Plugins::Lyphile::VLC::Control;

# Endpoints of the VLC player page.
#
#   POST plugins/Lyphile/vlc/atrack     player=<mac>&id=<audio track id of "atrack">   switch the audio
#                                                      track (command "atrack <id>"), then read
#                                                      "atrack" again: the answer has the streams as
#                                                      VLC now reports them, and "confirmed"
#   POST plugins/Lyphile/vlc/chapter    player=<mac>&id=<chapter number, from 0>   switch the chapter
#                                                      (command "chapter <id>"), then read "chapter"
#                                                      again: the answer has the chapters and
#                                                      "confirmed", as for atrack
#   POST plugins/Lyphile/vlc/transport  player=<mac>&action=<pause|stop>   pause (a toggle: pauses,
#                                                      or resumes when paused) or stop the Lyrion
#                                                      player; the events below pass it on to VLC
#   POST plugins/Lyphile/vlc/rcstatus   player=<mac>   is VLC's oldrc interface listening on the
#                                                      player's unix socket (see Bin/vlc-Player);
#                                                      when it is, also the input MRL (oldrc
#                                                      command "status"), the audio streams
#                                                      (commands "info" and "atrack") and the
#                                                      chapters (command "chapter"), the
#                                                      [Incoming] lines of "stats" and "now": the
#                                                      state ("status"), the time ("get_time",
#                                                      "get_length") and artist, album and title
#
#   POST plugins/Lyphile/vlc/tc        player=<mac>&bits=<16|24>&rate=<44100|48000|96000>   the PCM settings of the player
#                                                      (prefs tc_bits and tc_rate, read by Bin/vlc-Player when it starts;
#                                                      stereo always). Refused while VLC is running: they apply to the next
#                                                      track. Also in "rcstatus" as "tc".
#
# Every answer is JSON: { ok => true|false, error => "...", ... }.
#
# A switch of audio track or chapter is also written to the log of the run in progress,
# <player folder>/vlc-transcode-<mac>.log (Bin/vlc-Player appends that file to transcode.log when
# the run ends), as:
#     Command: atrack 2 -> 2 - Stereo - [English] *
# after the arrow what VLC reports as selected afterwards
#
# Events of Lyrion's own player that are passed on to VLC's oldrc interface of that player (when
# it is active):
#   playlist pause 1   VLC playing (state 3) -> "pause"      (pause toggles: it is only sent when
#   playlist pause 0   VLC paused  (state 4) -> "pause"       VLC is not in the state asked for)
#   playlist stop                            -> "stop"

use strict;
use warnings;

use HTTP::Status qw(RC_OK);
use File::Basename qw(dirname basename);
use IO::Select;
use IO::Socket::UNIX;
use JSON::XS;
use Time::HiRes ();

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

# Same folder and name as in Bin/vlc-Player: <dir>/<mac with dashes>/<mac with dashes>.sock
my $SOCKET_DIR = '/config/logs/lyphile/remote_players';

my %ENDPOINT = (
	rcstatus  => \&_rcstatus,
	transport => \&_transport,
	atrack    => \&_atrack,
	chapter   => \&_chapter,
	tc        => \&_tc,
);

sub init {
	Slim::Control::Request::subscribe(\&_onPlaylist, [['playlist'], ['pause', 'stop']]);

	foreach my $name (keys %ENDPOINT) {
		my $handler = $ENDPOINT{$name};

		Slim::Web::Pages->addPageFunction("plugins/Lyphile/vlc/$name", sub {
			my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
			return _send_json($httpClient, $httpResponse, $handler->($params));
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
	my $path   = socketFor($client->id) or return;
	my $sock   = _connect($path) or return;    # no VLC for this player: nothing to do

	if ($what eq 'stop') {
		_command($sock, 'stop', 1);
		$log->info('vlc: stop sent to ' . $client->id);
	}
	elsif ($what eq 'pause') {
		my $paused = $request->getRequest(2);
		$paused = $client->isPaused ? 1 : 0 unless defined $paused;

		# oldrc "pause" toggles, so look at VLC's state first: 3 playing, 4 paused. A paused VLC has no
		# "play state" line in its answer to "status": it says "Type 'pause' to continue." instead
		my $answer = _command($sock, 'status', 1) // '';
		my ($state) = $answer =~ /play state: (\d+)/;
		$state = 4 if !defined $state && $answer =~ /^Type 'pause' to continue\./m;
		$state //= -1;

		if (($paused && $state == 3) || (!$paused && $state == 4)) {
			_command($sock, 'pause', 1);
			$log->info('vlc: pause sent to ' . $client->id . ($paused ? ' (pause)' : ' (resume)'));
		}
		else {
			$log->debug('vlc: no pause sent to ' . $client->id . ", asked " . ($paused ? 'pause' : 'resume') . ", VLC state $state");
		}
	}

	close $sock;
}

sub _send_json {
	my ($httpClient, $httpResponse, $data) = @_;

	my $json = encode_json($data);
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	# the server sends the answer when the page function returns the reference to its body: sending it here as
	# well would answer the next request of the connection twice
	return \$json;
}

# Socket path of a player from its MAC address; undef for anything that is not a MAC address
sub socketFor {
	my $mac = lc(shift // '');
	return unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	$mac =~ tr/:/-/;
	return "$SOCKET_DIR/$mac/$mac.sock";
}

# One oldrc command: the text VLC answers, up to the line that matches $end (by default the
# closing "<command>: returned N (...)" line) or until $timeout seconds have passed. "info" has no
# such closing line, it ends with "+----[ end of stream info ]". Undef when the command could not
# be sent.
sub _command {
	my ($sock, $command, $timeout, $end) = @_;

	$end //= qr/^\Q$command\E: returned /m;

	print $sock "$command\n" or return;

	my $select   = IO::Select->new($sock);
	my $deadline = Time::HiRes::time() + $timeout;
	my $text     = '';

	while (Time::HiRes::time() <= $deadline && $text !~ $end) {
		next unless $select->can_read(0.2);
		my $n = sysread($sock, my $buf, 4096);
		last unless $n;
		$text .= $buf;
	}

	$text =~ s/\r//g;
	return $text;
}

# The play state out of the answer of "status":  status change: ( play state: 3 )
# VLC's states: 1 opening, 3 playing, 4 paused, 5 ended, 6 error
sub _state_of {
	my $status = shift // '';

	# a paused VLC has no "play state" line in its answer, it says how to go on
	return 'paused' if $status =~ /^Type 'pause' to continue\./m;

	my ($n) = $status =~ /^status change: \( play state: (\d+) \)/m;
	return '' unless defined $n;
	return { 1 => 'opening', 3 => 'playing', 4 => 'paused', 5 => 'stopped', 6 => 'error' }->{$n} // '';
}

# A number: get_time and get_length answer one bare line, with no closing "returned" line
sub _number_command {
	my ($sock, $command) = @_;

	my $text = _command($sock, $command, 1, qr/^-?\d+\s*$/m);
	my ($n) = ($text // '') =~ /^(-?\d+)\s*$/m;
	return defined $n ? $n + 0 : undef;
}

# get_title: the name of the playing item, one bare line (status notices skipped)
sub _title_command {
	my $sock = shift;

	my $text = _command($sock, 'get_title', 1, qr/^(?!status change:)[^\n]+\n/m) // '';
	my ($title) = grep { length && !/^status change:/ } map { s/\s+$//r } split /\n/, $text;
	return $title // '';
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

# The input MRL out of the answer of "status":  status change: ( new input: <MRL> )
sub _input_of {
	my $status = shift // '';
	return $status =~ /^status change: \( new input: (.*) \)\s*$/m ? $1 : '';
}

# Answer of "info" as a list of streams, each a hash of its "| Key: value" lines (plus "index"):
#   +----[ Stream 1 ]
#   | Codec: A52 Audio (aka AC3) (a52 )
#   | Type: Audio
sub _parse_info {
	my $text = shift // '';
	my (@streams, $cur);

	foreach my $line (split /\n/, $text) {
		if ($line =~ /^\+----\[ Stream (\d+) \]/) {
			$cur = { index => $1 };
			push @streams, $cur;
		}
		elsif ($line =~ /^\+----\[ /) {
			undef $cur;
		}
		elsif ($cur && $line =~ /^\| ([^:]+): (.*?)\s*$/) {
			$cur->{$1} = $2;
		}
	}

	return @streams;
}

# Answer of "atrack" as a list of { id, name, selected }, "Disable" (-1) left out:
#   +----[ Audio Track ]
#   | -1 - Disable
#   | 2 - Stereo - [English] *
#   +----[ end of Audio Track ]
sub _parse_atrack {
	my $text = shift // '';
	my (@tracks, $in);

	foreach my $line (split /\n/, $text) {
		if ($line =~ /^\+----\[ Audio Track \]/)        { $in = 1; next }
		if ($line =~ /^\+----\[ end of Audio Track \]/) { last }
		next unless $in;
		if ($line =~ /^\| (-?\d+) - (.*?)(\s+\*)?\s*$/ && $1 ne '-1') {
			push @tracks, { id => $1, name => $2, selected => $3 ? 1 : 0, line => "$1 - $2" . ($3 ? ' *' : '') };
		}
	}

	return @tracks;
}

# Answer of "chapter" without argument: the current chapter and the number of chapters, expected as
# "<current>/<count>" somewhere in the text ("Currently playing chapter 3/11"); VLC counts chapters
# from 0. Empty list when the text has no such pair.
sub _parse_chapter {
	my $text = shift // '';
	return $text =~ m{(\d+)\s*/\s*(\d+)} ? ($1, $2) : ();
}

# The chapters of the player page: [ { id, text, selected } ]. id is VLC's chapter number (from 0),
# text the number as people count them (from 1).
sub _chapters {
	my ($current, $count) = _parse_chapter(shift);
	return () unless defined $count && $count > 0;
	$count = 999 if $count > 999;

	return map { { id => $_, text => $_ + 1, selected => $_ == $current ? \1 : \0 } } 0 .. $count - 1;
}

# The audio streams of the player page: [ { id, text, selected } ]. The audio streams of "info" and
# the tracks of "atrack" are in the same order, so they are paired by position. The text is the
# fields that are there of: Codec, Description, Sample rate, Decoded channels, Decoded Bitrate.
sub _audio_streams {
	my ($info, $atrack) = @_;

	my @audio  = grep { ($_->{Type} // '') eq 'Audio' } _parse_info($info);
	my @tracks = _parse_atrack($atrack);

	my @streams;
	for my $i (0 .. ($#audio > $#tracks ? $#audio : $#tracks)) {
		my ($stream, $track) = ($audio[$i], $tracks[$i]);

		my $text = $stream ? join(' - ', grep { defined && length } (
			$stream->{Codec},
			$stream->{Description},
			$stream->{'Sample rate'}   // $stream->{'Decoded sample rate'},
			$stream->{'Decoded channels'} // $stream->{Channels},
			$stream->{'Decoded Bitrate'}  // $stream->{Bitrate},
		)) : '';
		$text = $track->{name} if !length($text) && $track;

		push @streams, {
			id       => $track ? $track->{id} : undef,
			text     => $text,
			selected => ($track && $track->{selected}) ? \1 : \0,
		};
	}

	return @streams;
}

# The lines of the [Incoming] part of the answer of "stats", as text without the "| " margin:
#   +-[Incoming]
#   | input bytes read :   368663 KiB
#   |
#   +-[Video Decoding]
sub _parse_stats {
	my $text = shift // '';
	my (@lines, $in);

	foreach my $line (split /\n/, $text) {
		if ($line =~ /^\+-\[Incoming\]/) { $in = 1; next }
		last if $in && $line =~ /^\+-/;
		next unless $in;
		push @lines, $1 if $line =~ /^\| (.*?)\s*$/ && length $1;
	}

	return @lines;
}

# Lines appended to the log of the run in progress (see the header). Nothing is written when there
# is no such file: it only exists while Bin/vlc-Player runs.
sub _runLog {
	my ($socket, @lines) = @_;

	(my $mac = basename($socket)) =~ s/\.sock$//;
	my $file = dirname($socket) . "/vlc-transcode-$mac.log";
	return unless -f $file;

	open(my $fh, '>>', $file) or return;
	print $fh map { "$_\n" } @lines;
	close $fh;
}

# A connection to the player's oldrc socket, or undef
sub _connect {
	my $path = shift;
	return unless -S $path;
	return IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path, Timeout => 1);
}

# The audio streams as VLC reports them now
sub _streams {
	my $sock = shift;

	my $info = _command($sock, 'info', 1, qr/\+----\[ end of stream info \]/);
	return _audio_streams($info, _command($sock, 'atrack', 1));
}

# Switch the audio track. The id must be one of the tracks "atrack" lists (a plain number: nothing
# else is ever written to the socket). VLC needs a moment before "atrack" shows the new track, so
# it is asked again, up to 5 times 0.2 s apart, until it shows the one that was asked for; what it
# shows last is the answer, whether that is the track asked for or not.
sub _atrack {
	my $params = shift;

	my $path = socketFor($params->{player});
	return { ok => \0, error => 'unknown player' } unless $path;

	my $id = $params->{id};
	return { ok => \0, error => 'bad audio track' } unless defined $id && $id =~ /^\d{1,9}$/;

	my $sock = _connect($path) or return { ok => \0, error => 'oldrc interface not active' };

	my @tracks = _parse_atrack(_command($sock, 'atrack', 1));
	unless (grep { $_->{id} eq $id } @tracks) {
		close $sock;
		return { ok => \0, error => 'unknown audio track' };
	}

	_command($sock, "atrack $id", 1);

	my ($confirmed, $now) = (0, undef);
	for my $try (1 .. 5) {
		select(undef, undef, undef, 0.2);
		($now) = grep { $_->{selected} } _parse_atrack(_command($sock, 'atrack', 1));
		if ($now && $now->{id} eq $id) { $confirmed = 1; last }
	}

	my @streams = _streams($sock);
	close $sock;

	_runLog($path, "  Command: atrack $id -> " . ($now ? $now->{line} : '(no audio track selected)')
		. ($confirmed ? '' : ' (VLC did not switch to that audio track)'));

	return { ok => \1, confirmed => $confirmed ? \1 : \0, streams => \@streams };
}

# Switch the chapter, same way as the audio track: the id is a plain number inside the chapters VLC
# reports, and "chapter" is asked again until it shows the chapter asked for (5 times, 0.2 s apart).
sub _chapter {
	my $params = shift;

	my $path = socketFor($params->{player});
	return { ok => \0, error => 'unknown player' } unless $path;

	my $id = $params->{id};
	return { ok => \0, error => 'bad chapter' } unless defined $id && $id =~ /^\d{1,3}$/;

	my $sock = _connect($path) or return { ok => \0, error => 'oldrc interface not active' };

	my @chapters = _chapters(_command($sock, 'chapter', 1));
	unless (grep { $_->{id} == $id } @chapters) {
		close $sock;
		return { ok => \0, error => 'unknown chapter' };
	}

	_command($sock, "chapter $id", 1);

	my $confirmed = 0;
	for my $try (1 .. 5) {
		select(undef, undef, undef, 0.2);
		my ($current) = _parse_chapter(_command($sock, 'chapter', 1));
		if (defined $current && $current == $id) { $confirmed = 1; last }
	}

	my $text = _command($sock, 'chapter', 1);
	@chapters = _chapters($text);
	close $sock;

	# what VLC answers to "chapter" now, without the closing "returned" line and status notices
	my @answer = grep { length && !/^chapter: returned / && !/^status change:/ } map { s/\s+$//r } split /\n/, $text // '';
	_runLog($path, "  Command: chapter $id -> " . (@answer ? join('; ', @answer) : '(no answer)')
		. ($confirmed ? '' : ' (VLC did not switch to that chapter)'));

	return { ok => \1, confirmed => $confirmed ? \1 : \0, chapters => \@chapters };
}

# The pause and stop buttons of the page act on Lyrion's player, as the buttons of Lyrion do. Its
# "playlist pause" and "playlist stop" events (see _onPlaylist) then reach VLC, so that Lyrion and
# VLC stay one: stopping VLC alone would make Lyrion see an end of stream.
sub _transport {
	my $params = shift;

	my $mac = lc($params->{player} // '');
	return { ok => \0, error => 'unknown player' } unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	my $client = Slim::Player::Client::getClient($mac) or return { ok => \0, error => 'unknown player' };

	my $action = $params->{action} // '';
	return { ok => \0, error => 'bad action' } unless $action eq 'pause' || $action eq 'stop';

	$client->execute([$action]);
	$log->info("vlc page: $action of $mac");

	return { ok => \1 };
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
# VLC is running (its oldrc socket answers) is refused.
sub _tc {
	my $params = shift;

	my $mac = lc($params->{player} // '');
	return { ok => \0, error => 'unknown player' } unless $mac =~ /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
	my $client = Slim::Player::Client::getClient($mac) or return { ok => \0, error => 'unknown player' };

	return { ok => \0, error => 'bad bits' } if defined $params->{bits} && $params->{bits} !~ /^(16|24)$/;
	return { ok => \0, error => 'bad rate' } if defined $params->{rate} && $params->{rate} !~ /^(44100|48000|96000)$/;

	return { ok => \0, error => 'playing' } if do { my $path = socketFor($mac); my $sock = $path && _connect($path); my $running = $sock ? 1 : 0; close $sock if $sock; $running };

	my $cprefs = $prefs->client($client);
	$cprefs->set('tc_bits', $params->{bits} + 0) if defined $params->{bits};
	$cprefs->set('tc_rate', $params->{rate} + 0) if defined $params->{rate};

	return { ok => \1, tc => _tc_state($mac) };
}

# Active = something accepts a connection on the socket. A socket file left behind by a dead VLC
# refuses the connection, so it counts as not active.
sub _rcstatus {
	my $params = shift;

	my $path = socketFor($params->{player});
	return { ok => \0, error => 'unknown player' } unless $path;

	my ($active, $input, @streams, @chapters, @stats, %now) = (0, '');
	if (my $sock = _connect($path)) {
		$active   = 1;
		my $status = _command($sock, 'status', 1);
		$input    = _input_of($status);
		@streams  = _streams($sock);
		@chapters = _chapters(_command($sock, 'chapter', 1));
		@stats    = _parse_stats(_command($sock, 'stats', 1, qr/end of statistical info/));

		%now = (state => _state_of($status), time => _number_command($sock, 'get_time'), length => _number_command($sock, 'get_length'));
		my $item = _title_command($sock);
		close $sock;

		# artist, album and title are Lyrion's; without them the name of the item in VLC is the title
		my ($artist, $album, $title) = eval { _lyrion_track($params->{player}) };
		@now{qw(artist album title)} = (defined $title && length $title) ? ($artist, $album, $title) : ('', '', $item);
		$now{cover} = eval { _lyrion_cover($params->{player}) } // '';
	}

	return { ok => \1, active => $active ? \1 : \0, input => $input, streams => \@streams, chapters => \@chapters, stats => \@stats, now => \%now, tc => _tc_state($params->{player}), socket => $path };
}

1;
