package Plugins::Lyphile::MPV::PlayerSettings;

# The mpv player page: a per-player settings page with two tabs, Player (what mpv plays, audio
# stream, chapter, statistics, artwork) and Control (PCM settings, equalizer), the same layout as the VLC pages.
# The page changes nothing by itself: it polls and sends requests to the Lyphile::MPV::Control endpoints.

use strict;
use warnings;
use parent qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lyphile');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LYPHILE_MPV');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Lyphile/settings/mpv/player.html');
}

sub validFor {
	my ($class, $client) = @_;

	# the mpv page is the only player page of a player given mpv-Player, and shown only then
	return $client && ($prefs->client($client)->get('selected_player') // '') eq 'mpv-Player';
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
		my $res = Plugins::Lyphile::MPV::Control::_tc({ player => $client->id, bits => $params->{tc_bits}, rate => $params->{tc_rate} });

		unless ($res && $res->{ok}) {
			my $why = ($res && $res->{error}) || 'failed';
			$params->{warning} .= 'Bit depth and Sample rate not saved: ' . ($why eq 'playing' ? 'a track is playing, stop it first' : $why) . '. ';
		}
	}

	return $class->SUPER::handler($client, $params);
}

1;
