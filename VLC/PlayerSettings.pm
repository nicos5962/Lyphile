package Plugins::Lyphile::VLC::PlayerSettings;

# The VLC player page (oldrc version): a per-player settings page with two tabs, Player and Control.
# It is shown unless the player was given vlc-Player-lua (Select Player), which has its own page,
# Plugins::Lyphile::VLC::PlayerSettingsLua, FFmpeg-Player or mpv-Player (their own pages).

use strict;
use warnings;
use parent qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lyphile');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LYPHILE_VLC');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Lyphile/settings/vlc/player.html');
}

sub validFor {
	my ($class, $client) = @_;

	my $selected = $client ? ($prefs->client($client)->get('selected_player') // '') : '';
	return $selected ne 'vlc-Player-lua' && $selected ne 'FFmpeg-Player' && $selected ne 'mpv-Player';
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

	return $class->SUPER::handler($client, $params);
}

1;
