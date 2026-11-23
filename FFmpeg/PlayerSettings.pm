package Plugins::Lyphile::FFmpeg::PlayerSettings;

# The ffmpeg player page: a per-player settings page with two tabs, Player and Control (same layout as the VLC
# pages). It is the only player page of a player that was given FFmpeg-Player (Select Player), and shown only then.

use strict;
use warnings;
use parent qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lyphile');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LYPHILE_FFMPEG');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Lyphile/settings/ffmpeg/player.html');
}

sub validFor {
	my ($class, $client) = @_;

	return $client && ($prefs->client($client)->get('selected_player') // '') eq 'FFmpeg-Player';
}

sub needsClient {
	return 1;
}

sub prefs {
	return ($prefs);
}

sub handler {
	my ($class, $client, $params) = @_;

	return $class->SUPER::handler($client, $params) unless $client;

	# Bit depth and Sample rate of the Control tab are the settings of this page: they are saved with Apply (or Yes
	# when the page is left). They are read when a track starts, so they are refused while a track plays.
	if ($params->{saveSettings} && (defined $params->{tc_bits} || defined $params->{tc_rate})) {
		my $res = Plugins::Lyphile::FFmpeg::Control::_tc({ player => $client->id, bits => $params->{tc_bits}, rate => $params->{tc_rate} });

		unless ($res && $res->{ok}) {
			my $why = ($res && $res->{error}) || 'failed';
			$params->{warning} .= 'Bit depth and Sample rate not saved: ' . ($why eq 'playing' ? 'a track is playing, stop it first' : $why) . '. ';
		}
	}

	return $class->SUPER::handler($client, $params);
}

1;
