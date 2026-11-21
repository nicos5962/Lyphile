package Plugins::Lyphile::VLC::PlayerSettingsLua;

# The VLC player page (Lua version): the same page as Plugins::Lyphile::VLC::PlayerSettings, for a
# player that was given vlc-Player-lua in Select Player (VLC is controlled through its Lua HTTP
# interface, see Plugins::Lyphile::VLC::ControlLua). It is shown only then.

use strict;
use warnings;
use parent qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.lyphile');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LYPHILE_VLC_LUA');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Lyphile/settings/vlc/player-lua.html');
}

sub validFor {
	my ($class, $client) = @_;

	return $client && ($prefs->client($client)->get('selected_player') // '') eq 'vlc-Player-lua';
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
