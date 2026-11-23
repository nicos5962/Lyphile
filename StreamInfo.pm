package Plugins::Lyphile::StreamInfo;

# Endpoint of the "Now playing" frame of the Lyphile skin:
#
#   POST plugins/Lyphile/streaminfo   player=<mac>
#       { ok => true, text => "<details of the audio stream being played>" }
#
# The text is the selected audio stream as the player page of the helper of that player shows it.
# It is empty when the player has no helper ("none"), is not playing, or the helper has no answer;
# the frame then keeps the bitrate line of the core.

use strict;
use warnings;

use HTTP::Status qw(RC_OK);
use JSON::XS;

use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lyphile');

my %STATUS = (
	'vlc-Player'      => sub { Plugins::Lyphile::VLC::Control::_rcstatus(@_) },
	'vlc-Player-lua'  => sub { Plugins::Lyphile::VLC::ControlLua::_rcstatus(@_) },
	'FFmpeg-Player'   => sub { Plugins::Lyphile::FFmpeg::Control::_rcstatus(@_) },
	'mpv-Player'      => sub { Plugins::Lyphile::MPV::Control::_rcstatus(@_) },
);

sub init {
	Slim::Web::Pages->addPageFunction('plugins/Lyphile/streaminfo', sub {
		my ($client, $params, $callback, $httpClient, $httpResponse) = @_;
		return _send_json($httpClient, $httpResponse, _streaminfo($params));
	});
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

sub _streaminfo {
	my $params = shift;

	my $mac    = lc($params->{player} // '');
	my $client = $mac =~ /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/ ? Slim::Player::Client::getClient($mac) : undef;
	my $none   = { ok => \1, text => '' };

	return $none unless $client;

	my $helper = $prefs->client($client)->get('selected_player') // '';
	my $status = $STATUS{$helper} or return $none;

	# nothing to ask a helper that does not play
	my $mode = eval { Slim::Player::Source::playmode($client) } // '';
	return $none unless $mode eq 'play' || $mode eq 'pause';

	my $res = eval { $status->({ player => $mac }) };
	return $none unless ref $res eq 'HASH' && $res->{ok} && $res->{active};

	my @streams = @{ $res->{streams} || [] };
	# "selected" is a JSON boolean: a reference to 1 or 0
	my ($sel) = grep { ref $_->{selected} ? ${ $_->{selected} } : $_->{selected} } @streams;
	$sel ||= $streams[0];

	# the frame has little room: the text between parentheses is left out
	my $text = $sel ? ($sel->{text} // '') : '';
	$text =~ s/\s*\([^)]*\)//g;
	$text =~ s/\s{2,}/ /g;

	return { ok => \1, text => $text };
}

1;
