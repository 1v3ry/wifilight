##############################################
# $Id: 32_WifiLight.pm 87 2015-06-30 12:30:00Z herrmannj $

# TODO
# doku


# versions
# 51 new milight color converter
# 52 timing for transitions: drop frames if required
# 53 transition names and events
# 54 drop frames ll add-on / lock ll queue
# 55 add ll queue lock count
# 56 RGB in
# 57 bridge v2
# 58 gamma correction 
# 59 fix "off" with ramp
# 60 add dimup/dimdown
# 61 introduce dimSteps
# 62 introduce defaultColor
# 63 LW12 define if lw12 is unavailable at startup
# 64 transition with ramp 0 fixed
# 65 some typos with impact to RGBW1 and RGBW2
# 66 readings: lower camelCase and limited trigger
# 67 restore state after startup
# 68 LW12 reconnect after timeout
# 69 RGBW1 timing improved
# 70 colorpicker
# 71 default ramp attrib
# 72 add LD316
# 73 add LD382
# 74 add color calibration (hue intersections) for RGB type controller
# 75 add white point adjustment for RGB type controller
# 76 add LW12 HX001
# 77 milight RGBW2: critical cmds sendout repeatly
# 78 add attrib for color managment (rgb types)
# 79 add LD382 RGB ony mode
# 80 HSV2fourChannel bug fixed (thnx to lexorius)
# 81 LW12FC added 
# 82 LD382A (FW 1.0.6)
# 83 fixed ramp handling (thnx to henryk)
# 84 sengled boost added (thnx to scooty)
# 85 milight white, improved reliability
# 86 milight white, improved reliability / mark II
# 87 milight rgbw2, dim bug

# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)

package main;

use strict;
use warnings;

use IO::Handle;
use IO::Socket;
use IO::Select;
use Time::HiRes;
use Data::Dumper;

use Color;

sub
WifiLight_Initialize(@)
{

  my ($hash) = @_;

  FHEM_colorpickerInit();

  $hash->{DefFn}   = "WifiLight_Define";
  $hash->{UndefFn} = "WifiLight_Undef";
  $hash->{ShutdownFn} = "WifiLight_Undef";
  $hash->{SetFn} = "WifiLight_Set";
  $hash->{GetFn} = "WifiLight_Get";
  $hash->{AttrFn} = "WifiLight_Attr";
  $hash->{NotifyFn}  = "WifiLight_Notify";
  $hash->{AttrList}     = "gamma dimStep defaultColor defaultRamp colorCast whitePoint";

  return undef;
}

sub
WifiLight_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def); 
  my $name = $a[0];
  my $key;

  return "wrong syntax: define <name> WifiLight <type> <connection>" if(@a != 4);
  return "unknown LED type ($a[2]): choose one of RGB, RGBW, RGBW1, RGBW2, White" unless (grep /$a[2]/, ('RGB', 'RGBW', 'RGBW1', 'RGBW2', 'White')); 
  
  $hash->{LEDTYPE} = $a[2];
  my $otherLights;

  if ($a[3] =~ m/(bridge-V2):([^:]+):*(\d+)*/g)
  {
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:50000;
    $hash->{PROTO} = 0;
    #my @hlCmdQueue = [];
    @{$hash->{helper}->{hlCmdQueue}} = (); #\@hlCmdQueue;
    # $hash->{SERVICE} = 48899; unkown for v2
    # search if this bridge is already defined 
    # if so, we need a shared buffer (llCmdQueue), shared socket and we need to check if the requied slot is free
    foreach $key (keys %defs) 
    {
      if (($defs{$key}{TYPE} eq 'WifiLight') && ($defs{$key}{IP} eq $hash->{IP}) && ($key ne $name))
      {
        #bridge is in use
        Log3 (undef, 3, "WifiLight: requested bridge $hash->{CONNECTION} at $hash->{IP} already in use by $key, copy llCmdQueue");
        $hash->{helper}->{llCmdQueue} = $defs{$key}{helper}{llCmdQueue};
        $hash->{helper}->{llLock} = 0;
        $hash->{helper}->{SOCKET} = $defs{$key}{helper}{SOCKET};
        $hash->{helper}->{SELECT} = $defs{$key}{helper}{SELECT};
        my $slotInUse = $defs{$key}{SLOT};
        $otherLights->{$slotInUse} = $defs{$key};
      }
    } 
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => 48899,
        Blocking => 0,
        Proto => 'udp',
        Broadcast => 1) or return "can't bind: $@";
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = {};
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(bridge-V3):([^:]+):*(\d+)*/g)
  {
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:8899;
    $hash->{PROTO} = 0;
    #my @hlCmdQueue = [];
    @{$hash->{helper}->{hlCmdQueue}} = (); #\@hlCmdQueue;
    # $hash->{SERVICE} = 48899;
    # search if this bridge is already defined 
    # if so, we need a shared buffer (llCmdQueue), shared socket and we need to check if the requied slot is free
    foreach $key (keys %defs) 
    {
      if (($defs{$key}{TYPE} eq 'WifiLight') && ($defs{$key}{IP} eq $hash->{IP}) && ($key ne $name))
      {
        #bridge is in use
        Log3 (undef, 3, "WifiLight: requested bridge $hash->{CONNECTION} at $hash->{IP} already in use by $key, copy llCmdQueue");
        $hash->{helper}->{llCmdQueue} = $defs{$key}{helper}{llCmdQueue};
        $hash->{helper}->{llLock} = 0;
        $hash->{helper}->{SOCKET} = $defs{$key}{helper}{SOCKET};
        $hash->{helper}->{SELECT} = $defs{$key}{helper}{SELECT};
        my $slotInUse = $defs{$key}{SLOT};
        $otherLights->{$slotInUse} = $defs{$key};
      }
    } 
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => 48899,
        Blocking => 0,
        Proto => 'udp',
        Broadcast => 1) or return "can't bind: $@";
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }
  
  if ($a[3] =~ m/(LW12):([^:]+):*(\d+)*/g)
  {
    return "only RGB supported by LW12" if ($a[2] ne "RGB"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5577;
    $hash->{PROTO} = 1;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(LW12HX):([^:]+):*(\d+)*/g)
  {
    return "only RGB supported by LW12HX" if ($a[2] ne "RGB"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5000;
    $hash->{PROTO} = 1;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(LW12FC):([^:]+):*(\d+)*/g)
  {
    return "only RGB supported by LW12FC" if ($a[2] ne "RGB"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5000;
    #$hash->{PROTO} = 1;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Blocking => 0,
        Proto => 'udp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(LD316):([^:]+):*(\d+)*/g)
  {
    return "only RGBW supported by LD316" if ($a[2] ne "RGBW"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5577;
    $hash->{PROTO} = 1;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(LD382):([^:]+):*(\d+)*/g)
  {
    return "only RGB and RGBW supported by LD382" if (($a[2] ne "RGB") && ($a[2] ne "RGBW"));
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5577;
    $hash->{PROTO} = 1;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }

  if ($a[3] =~ m/(LD382A):([^:]+):*(\d+)*/g)
  {
    return "only RGB and RGBW supported by LD382A" if (($a[2] ne "RGB") && ($a[2] ne "RGBW"));
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:5577;
    $hash->{PROTO} = 1;
    #$hash->{SERVICE} = 48899;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }
  
if ($a[3] =~ m/(SENGLED):([^:]+):*(\d+)*/g)
  {
    return "only White supported by SENGLED" if ($a[2] ne "White"); 
    $hash->{CONNECTION} = $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:9060;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Blocking => 0,
        Proto => 'udp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
      @{$hash->{helper}->{llCmdQueue}} = ();
      $hash->{helper}->{llLock} = 0;
    }
  }
  
if ($a[3] =~ m/(LK35):([^:]+):*(\d+)*/gi)
  {
    $hash->{CONNECTION} = uc $1;
    $hash->{IP} = $2;
    $hash->{PORT} = $3?$3:8899;
    $hash->{PROTO} = 1;
    $hash->{SLOT} = 0;
    @{$hash->{helper}->{hlCmdQueue}} = ();
    @{$hash->{helper}->{llCmdQueue}} = ();
    $hash->{helper}->{llLock} = 0;
    if (!defined($hash->{helper}->{SOCKET}))
    {
      my $sock = IO::Socket::INET-> new (
        PeerPort => $hash->{PORT},
        PeerAddr => $hash->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($hash, 3, "define $hash->{NAME}: can't reach ($@)");
      my $select = IO::Select->new($sock);
      $hash->{helper}->{SOCKET} = $sock;
      $hash->{helper}->{SELECT} = $select;
    }
  }

  return "unknown connection type: choose one of bridge-V3:<ip>|LW12:<ip>|LW12HX:<ip>|LD316:<ip>|LD382:<ip>|SENGLED:<ip>|LK35:<ip> " if !(defined($hash->{CONNECTION})); 

  Log3 ($hash, 4, "define $a[0] $a[1] $a[2] $a[3]");

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LW12'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 0.75, 0.25';
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LW12HX'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 0.75, 0.25';   
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LW12FC'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.85);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 0.85, 0.55';   
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGBW') && ($hash->{CONNECTION} =~ 'LD316'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -25, -15, -25, 0, -20';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1.0, 0.6, 0.065';
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGBW') && ($hash->{CONNECTION} =~ 'LD382'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 1, 1';
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LD382'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 0.75, 0.25';
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGBW') && ($hash->{CONNECTION} =~ 'LD382A'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 1, 1';
    return undef;
  }

  if (($hash->{LEDTYPE} eq 'RGB') && ($hash->{CONNECTION} =~ 'LD382A'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge";
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10';
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 0.75, 0.25';
    return undef;
  }

  if ((($hash->{LEDTYPE} eq 'RGB') || ($hash->{LEDTYPE} eq 'RGBW1')) && ($hash->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}" if (defined($otherLights->{0}));
    $hash->{SLOT} = 0;
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 1);
    $hash->{helper}->{COLORMAP} = WifiLight_Milight_ColorConverter($hash);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge sync pair unpair";
    #if we are allready paired: sync to get a defined state
    return WifiLight_RGB_Sync($hash) if ($hash->{LEDTYPE} eq 'RGB');
    return WifiLight_RGBW1_Sync($hash) if ($hash->{LEDTYPE} eq 'RGBW1');
  }
  elsif (($hash->{LEDTYPE} eq 'RGBW2')  && ($hash->{CONNECTION} =~ 'bridge-V3'))
  {
    # find a free slot
    my $i = 5;
    while (defined($otherLights->{$i}))
    {
      $i++;
    }
    if ( grep { $i == $_ } 5..8 )
    { 
      $hash->{SLOT} = $i;
      $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.73);
      $hash->{helper}->{COLORMAP} = WifiLight_Milight_ColorConverter($hash);
      $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown HSV RGB hue redye saturation tinge sync pair unpair";
      return WifiLight_RGBW2_Sync($hash);
    }
    else
    {
      return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}";
    }
  }
  elsif (($hash->{LEDTYPE} eq 'White')  && ($hash->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    # find a free slot
    my $i = 1;
    while (defined($otherLights->{$i}))
    {
      $i++;
    }
    if ( grep { $i == $_ } 1..4 )
    { 
      $hash->{SLOT} = $i;
      $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.8);
      $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown sync pair unpair";
      return WifiLight_White_Sync($hash);
    }
    else
    {
      return "no free slot at $hash->{CONNECTION} ($hash->{IP}) for $hash->{LEDTYPE}";
    }
  }
  
  if (($hash->{LEDTYPE} eq 'White') && ($hash->{CONNECTION} =~ 'SENGLED'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 1);
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown";
    return undef;
  }
  
  if (($hash->{LEDTYPE} eq 'RGBW') && ($hash->{CONNECTION} eq 'LK35'))
  {
    $hash->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($hash, 0.65); # TODO CHECK VALUES
    $hash->{helper}->{COMMANDSET} = "on off dim dimup dimdown RGB RGBW R G B W";
    $hash->{helper}->{rLevel} = 0;
    $hash->{helper}->{gLevel} = 0;
    $hash->{helper}->{bLevel} = 0;
    $hash->{helper}->{wLevel} = 0;
	$hash->{helper}->{brightness} = 8;
    # color cast defaults in r,y, g, c, b, m: +/-30°
    my $cc = '0, -20, -20, -25, 0, -10'; # TODO CHECK VALUES
    $attr{$name}{"colorCast"} = $cc;
    WifiLight_RGB_ColorConverter($hash, split(',', $cc));
    # white point defaults in r,g,b
    $attr{$name}{"whitePoint"} = '1, 1, 1';
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "brightness", 0);
	readingsBulkUpdate($hash, "red", 0);
	readingsBulkUpdate($hash, "green", 0);
	readingsBulkUpdate($hash, "blue", 0);
	readingsBulkUpdate($hash, "white", 0);
	readingsBulkUpdate($hash, "RGB", "000000");
	readingsBulkUpdate($hash, "RGBW", "00000000");
	readingsBulkUpdate($hash, "state", "off");
	readingsEndUpdate($hash, 1);
    return undef;
  }
  
  return "$hash->{LEDTYPE} is not supported at $hash->{CONNECTION} ($hash->{IP})";
}

sub
WifiLight_Undef(@)
{
  return undef;
}

sub
WifiLight_Set(@)
{
  my ($ledDevice, $name, $cmd, @args) = @_;
  my $cnt = @args;
  my $ramp = 0;
  my $flags = "";
  my $event = undef;

  my $cmdSet = $ledDevice->{helper}->{COMMANDSET}; 
  return "unknown command ($cmd): choose one of ".join(", ", $cmdSet) if ($cmd eq "?"); 
  return "unknown command ($cmd): choose one of ".$ledDevice->{helper}->{COMMANDSET} if ($cmd ne 'RGB') and not ( grep { $cmd eq $_ } split(" ", $ledDevice->{helper}->{COMMANDSET} ));

  if ($cmd eq 'pair')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name pair [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGB_Pair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Pair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Pair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Pair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'unpair')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name unpair [seconds]" if ($args[0] !~ /^\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGB_UnPair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_UnPair($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_UnPair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_UnPair($ledDevice, $ramp) if ($ledDevice->{LEDTYPE} eq 'White');
  }

  if ($cmd eq 'sync')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    return WifiLight_RGB_Sync($ledDevice) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Sync($ledDevice) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Sync($ledDevice) if ($ledDevice->{LEDTYPE} eq 'RGBW2');
    return WifiLight_White_Sync($ledDevice) if ($ledDevice->{LEDTYPE} eq 'White');
  }
  
  if (($cmd eq 'HSV') || ($cmd eq 'RGB') || ($cmd eq 'hue') || ($cmd eq 'redye') || ($cmd eq 'saturation') || ($cmd eq 'tinge') || ($cmd eq 'dim'))
  {
    $args[1] = AttrVal($ledDevice->{NAME}, "defaultRamp", 0) if !defined($args[1]);
  }
  else
  {
    $args[0] = AttrVal($ledDevice->{NAME}, "defaultRamp", 0) if !defined($args[0]);
  }

  if ($cmd eq 'on')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name on [seconds]" if ($args[0] !~ /^\d?.?\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGBWLD316_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
    return WifiLight_RGBWLD382_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBLD382_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBWLD382A_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLD382A_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLW12_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGBLW12HX_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12HX'));
    return WifiLight_RGBLW12FC_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12FC'));
    return WifiLight_WhiteSENGLED_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
    return WifiLight_RGB_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} eq 'bridge-V3'));
    return WifiLight_White_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	return WifiLight_LK35_On($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
  }

  if ($cmd eq 'off')
  {
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    if (defined($args[0]))
    {
      return "usage: set $name off [seconds]" if ($args[0] !~ /^\d?.?\d+$/);
      $ramp = $args[0];
    }
    return WifiLight_RGBWLD316_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
    return WifiLight_RGBWLD382_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBLD382_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBWLD382A_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLD382A_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLW12_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGBLW12HX_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12HX'));
    return WifiLight_RGBLW12FC_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12FC'));
    return WifiLight_WhiteSENGLED_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
    return WifiLight_RGB_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} eq 'bridge-V3'));
    return WifiLight_White_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	return WifiLight_LK35_Off($ledDevice, $ramp) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
  }

  if ($cmd eq 'dimup')
  {
    return "usage: set $name dimup" if (defined($args[1]));
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    my $v = ReadingsVal($ledDevice->{NAME}, "brightness", 0) + AttrVal($ledDevice->{NAME}, "dimStep", 7);
    $v = 100 if $v > 100;
    return WifiLight_RGBWLD316_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
    return WifiLight_RGBWLD382_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBLD382_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBWLD382A_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLD382A_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLW12_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGBLW12HX_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12HX'));
    return WifiLight_RGBLW12FC_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12FC'));
    return WifiLight_WhiteSENGLED_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
    return WifiLight_RGB_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} eq 'bridge-V3'));
    return WifiLight_White_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	return WifiLight_LK35_Dim($ledDevice, ReadingsVal($ledDevice->{NAME}, "brightness", 0)+1, 0, '') if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35') && ReadingsVal($ledDevice->{NAME}, "brightness", 0) < 8);
  }

  if ($cmd eq 'dimdown')
  {
    return "usage: set $name dimdown" if (defined($args[1]));
    WifiLight_HighLevelCmdQueue_Clear($ledDevice);
    my $v = ReadingsVal($ledDevice->{NAME}, "brightness", 0) - AttrVal($ledDevice->{NAME}, "dimStep", 7);
    $v = 0 if $v < 0;
    return WifiLight_RGBWLD316_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
    return WifiLight_RGBWLD382_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBLD382_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBWLD382A_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLD382A_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLW12_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGBLW12HX_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12HX'));
    return WifiLight_RGBLW12FC_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12FC'));
    return WifiLight_WhiteSENGLED_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
    return WifiLight_RGB_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} eq 'bridge-V3'));
    return WifiLight_White_Dim($ledDevice, $v, 0, '') if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	return WifiLight_LK35_Dim($ledDevice, ReadingsVal($ledDevice->{NAME}, "brightness", 0)-1, 0, '') if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35') && ReadingsVal($ledDevice->{NAME}, "brightness", 0) > 0);
  }

  if ($cmd eq 'dim')
  {
    return "usage: set $name dim level [seconds]" if ($args[0] !~ /^\d+$/);
    return "usage: set $name dim level [seconds]" if (($args[0] < 0) || ($args[0] > 100));
    if (defined($args[1]))
    {
      return "usage: set $name dim level [seconds] [q]" if ($args[1] !~ /^\d?.?\d+$/);
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return "usage: set $name dim level seconds [q]" if ($args[2] !~ m/.*[qQ].*/);
      $flags = $args[2];
    }
    WifiLight_HighLevelCmdQueue_Clear($ledDevice) if ($flags !~ m/.*[qQ].*/);
    return WifiLight_RGBWLD316_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
    return WifiLight_RGBWLD382_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBLD382_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
    return WifiLight_RGBWLD382A_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLD382A_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
    return WifiLight_RGBLW12_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12'));
    return WifiLight_RGBLW12HX_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12HX'));
    return WifiLight_RGBLW12FC_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LW12FC'));
    return WifiLight_WhiteSENGLED_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
    return WifiLight_RGB_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW1_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    return WifiLight_RGBW2_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} eq 'bridge-V3'));
    return WifiLight_White_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	return WifiLight_LK35_Dim($ledDevice, $args[0], $ramp, $flags) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
  }

  if (($cmd eq 'HSV') || ($cmd eq 'RGB') || ($cmd eq 'hue') || ($cmd eq 'redye') || ($cmd eq 'saturation') ||($cmd eq 'tinge'))
  {
    my ($hue, $sat, $val);
	my ($r, $g, $b);
    
    if ($cmd eq 'HSV')
    {
      return "HSV is required as h,s,v" if (defined($args[0]) && $args[0] !~ /^\d{1,3},\d{1,3},\d{1,3}$/);
      ($hue, $sat, $val) = split(',', $args[0]);
      return "wrong hue ($hue): valid range 0..360" if !(($hue >= 0) && ($hue <= 360));
      return "wrong saturation ($sat): valid range 0..100" if !(($sat >= 0) && ($sat <= 100));
      return "wrong brightness ($val): valid range 0..100" if !(($val >= 0) && ($val <= 100));
    }
    elsif ($cmd eq 'RGB')
    {
      return "RGB is required hex RRGGBB" if (defined($args[0]) && $args[0] !~ /^[0-9A-Fa-f]{6}$/);
      ($hue, $sat, $val) = WifiLight_RGB2HSV($ledDevice, $args[0]);  
	  $r = hex substr $args[0], 0, 2;
	  $g = hex substr $args[0], 2, 2;
	  $b = hex substr $args[0], 4, 2;
    }
    elsif ($cmd eq 'hue' || $cmd eq 'redye') 
    {
      if($cmd eq 'hue') 
      {
        $hue = $args[0];
        return "invalid hue ($hue): expected positive integer" if ($hue !~ /^\d+$/);
        return "invalid hue ($hue): valid range 0..360" if ($hue < 0 || $hue > 360);
      } 
      elsif($cmd eq 'redye') 
      {
        my $hue_delta = $args[0];
        return "invalid hue delta ($hue_delta): expected integer" if ($hue_delta !~ /^-?\d+$/);
        $hue = (ReadingsVal($ledDevice->{NAME}, "hue", 0) + $hue_delta) % 360;
      }
      $sat = ReadingsVal($ledDevice->{NAME}, "saturation", 100);
      $val = ReadingsVal($ledDevice->{NAME}, "brightness", 100);
    }
    elsif ($cmd eq 'saturation' || $cmd eq 'tinge') 
    {
      if($cmd eq 'saturation') 
      {
        $sat = $args[0];
        return "invalid saturation ($sat): expected positive integer" if ($sat !~ /^\d+$/);
        return "invalid saturation ($sat): valid range 0..100" if ($sat < 0 || $sat > 100);
      } 
      elsif($cmd eq 'tinge') 
      {
        my $sat_delta = $args[0];
        return "invalid sat delta ($sat_delta): expected integer" if ($sat_delta !~ /^-?\d+$/);
        $sat = ReadingsVal($ledDevice->{NAME}, "saturation", 0) + $sat_delta;
        if($sat < 0) {
          $sat = 0;
        } elsif($sat > 100) {
          $sat = 100;
        }
      }
      $hue = ReadingsVal($ledDevice->{NAME}, "hue", 0);
      $val = ReadingsVal($ledDevice->{NAME}, "brightness", 100);
    }

    if (defined($args[1]))
    {
      return "usage: set $name HSV H,S,V seconds flags programm" if ($args[1] !~ /^\d?.?\d+$/);
      $ramp = $args[1];
    }
    if (defined($args[2]))
    {   
      return "usage: set $name HSV H,S,V seconds [slq] programm" if ($args[2] !~ m/.*[sSlLqQ].*/);
      $flags = $args[2];
    }
    if (defined($args[3]))
    {   
      return "usage: set $name HSV H,S,V seconds flags programm=[A-Za-z_0-9]" if ($args[3] !~ m/[A-Za-z_0-9]*/);
      $event = $args[3];
    }
    WifiLight_HighLevelCmdQueue_Clear($ledDevice) if ($flags !~ m/.*[qQ].*/);
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LD316');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LD382');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LD382A');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LW12');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LW12HX');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 100, $event) if ($ledDevice->{CONNECTION} eq 'LW12FC');
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 500, $event) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 1000, $event) if (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
    WifiLight_HSV_Transition($ledDevice, $hue, $sat, $val, $ramp, $flags, 200, $event) if (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
	WifiLight_LK35_setRGB($ledDevice, $r, $g, $b, $ramp) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
    return WifiLight_SetHSV_Target($ledDevice, $hue, $sat, $val);
  }
  
  if ($cmd eq 'RGBW')
  {
    my ($r, $g, $b, $w);
    return "RGBW is required hex RRGGBBWW" if (defined($args[0]) && $args[0] !~ /^[0-9A-Fa-f]{8}$/);
    $r = hex substr $args[0], 0, 2;
    $g = hex substr $args[0], 2, 2;
    $b = hex substr $args[0], 4, 2;
    $w = hex substr $args[0], 6, 2;
    WifiLight_LK35_setRGBW($ledDevice, $r, $g, $b, $w, $ramp) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
  }
  
  if (($cmd eq 'R') || ($cmd eq 'G') || ($cmd eq 'B') || ($cmd eq 'W'))
  {
	if (defined($args[1]))
    {
      return "usage: set $name CHANNEL value" if ($args[1] !~ /^(\d+)$/);
      $ramp = $args[1];
    }
	
	my ($color, $value);
    $color = $cmd;
	$value = int $args[0];
	
	if($value < 0 || $value > 255)
	{
		return "value must be a number between 0 and 255";
	}
	
    WifiLight_LK35_setColor($ledDevice, $color, $value) if (($ledDevice->{LEDTYPE} =~ 'RGBW') && ($ledDevice->{CONNECTION} =~ 'LK35'));
  }
}

sub
WifiLight_Get(@)
{
  my ($ledDevice, $name, $cmd, @args) = @_;
  my $cnt = @args;
  
  return undef;
}

sub
WifiLight_Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $ledDevice = $defs{$device};

  if ($cmd eq 'set' && $attribName eq 'gamma')
  {
    return "gamma is required as numerical value (eg. 0.5 or 2.2)" if ($attribVal !~ /^\d*\.\d*$/);
    $ledDevice->{helper}->{GAMMAMAP} = WifiLight_CreateGammaMapping($ledDevice, $attribVal);
  }
  if ($cmd eq 'set' && $attribName eq 'dimStep')
  {
    return "dimStep is required as numerical value [1..100]" if ($attribVal !~ /^\d*$/) || (($attribVal < 1) || ($attribVal > 100));
  }
  if ($cmd eq 'set' && $attribName eq 'defaultColor')
  {
    return "defaultColor is required as HSV" if ($attribVal !~ /^\d{1,3},\d{1,3},\d{1,3}$/);
    my ($hue, $sat, $val) = split(',', $attribVal);
    return "defaultColor: wrong hue ($hue): valid range 0..360" if !(($hue >= 0) && ($hue <= 360));
    return "defaultColor: wrong saturation ($sat): valid range 0..100" if !(($sat >= 0) && ($sat <= 100));
    return "defaultColor: wrong brightness ($val): valid range 0..100" if !(($val >= 0) && ($val <= 100));
  }
  my @a = ();
  if ($cmd eq 'set' && $attribName eq 'colorCast')
  {
    @a = split(',', $attribVal);
    my $msg =  "colorCast: correction require red, yellow, green ,cyan, blue, magenta (each in a range of -29 .. 29)";
    return $msg unless (@a == 6);  
    foreach my $tc (@a)
    {
      return $msg unless ($tc =~ m/^\s*[\-]{0,1}[0-9]+[\.]{0,1}[0-9]*\s*$/g);
      return $msg if (abs($tc) >= 30);
    }
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LD316');
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LD382');
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LD382A');
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LW12');
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LW12HX');
    WifiLight_RGB_ColorConverter($ledDevice, @a) if ($ledDevice->{CONNECTION} eq 'LW12FC');
    if ($init_done && !(@{$ledDevice->{helper}->{hlCmdQueue}}))
    {
      my $hue = $ledDevice->{READINGS}->{hue}->{VAL};
      my $sat = $ledDevice->{READINGS}->{saturation}->{VAL};
      my $val = $ledDevice->{READINGS}->{brightness}->{VAL};
      WifiLight_setHSV($ledDevice, $hue, $sat, $val, 1);
    }
  }
  if ($cmd eq 'set' && $attribName eq 'whitePoint')
  {
    @a = split(',', $attribVal);
    my $msg =  "whitePoint: correction require red, green, blue (each in a range of 0.0 ..1.0)";
    return $msg unless (@a == 3);  
    foreach my $tc (@a)
    {
      return $msg unless ($tc =~ m/^\s*[0-9]+?[\.]{0,1}[0-9]*\s*$/g);
      return $msg if (($tc < 0) || ($tc > 1));
    }
    if ($init_done && !(@{$ledDevice->{helper}->{hlCmdQueue}}))
    {
      $attr{$device}{"whitePoint"} = $attribVal;
      my $hue = $ledDevice->{READINGS}->{hue}->{VAL};
      my $sat = $ledDevice->{READINGS}->{saturation}->{VAL};
      my $val = $ledDevice->{READINGS}->{brightness}->{VAL};
      WifiLight_setHSV($ledDevice, $hue, $sat, $val, 1);
    }
  }

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} attrib $attribName $cmd $attribVal") if $attribVal; 
  return undef;
}

# restore previous settings (as set statefile)
sub
WifiLight_Notify(@)
{
  my ($ledDevice, $eventSrc) = @_;
  my $events = deviceEvents($eventSrc, 1);
  my ($hue, $sat, $val);

  # wait for global: INITIALIZED after start up
  if ($eventSrc->{NAME} eq 'global' && @{$events}[0] eq 'INITIALIZED')
  {
    #######################################################
    # TODO remove in a few weeks. its here for convenience
    delete($ledDevice->{READINGS}->{HUE});
    delete($ledDevice->{READINGS}->{SATURATION});
    delete($ledDevice->{READINGS}->{BRIGHTNESS});
    #######################################################
    if ($ledDevice->{CONNECTION} eq 'LW12') 
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBLW12_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif ($ledDevice->{CONNECTION} eq 'LW12HX') 
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBLW12HX_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif ($ledDevice->{CONNECTION} eq 'LW12FC') 
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBLW12FC_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif ($ledDevice->{CONNECTION} eq 'LD316')
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBWLD316_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif ($ledDevice->{CONNECTION} eq 'LD382')
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBWLD382_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif ($ledDevice->{CONNECTION} eq 'LD382A')
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBWLD382A_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:60;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:100;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_RGB_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGBW1') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:50;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_RGBW1_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'RGBW2') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:0;
      return WifiLight_RGBW2_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_White_setHSV($ledDevice, $hue, $sat, $val);
    }
    elsif (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'))
    {
      $hue = defined($ledDevice->{READINGS}->{hue}->{VAL})?$ledDevice->{READINGS}->{hue}->{VAL}:0;
      $sat = defined($ledDevice->{READINGS}->{saturation}->{VAL})?$ledDevice->{READINGS}->{saturation}->{VAL}:0;
      $val = defined($ledDevice->{READINGS}->{brightness}->{VAL})?$ledDevice->{READINGS}->{brightness}->{VAL}:100;
      return WifiLight_WhiteSENGLED_setHSV($ledDevice, $hue, $sat, $val);
    }
    else
    {
    }
    return 
  }
}

###############################################################################
#
# device specific controller functions RGBW LD316
# aka XScource 
#
#
###############################################################################

sub
WifiLight_RGBWLD316_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c", 0xCC, 0x23, 0x33);
  my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD316 set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBWLD316_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD316 set off $ramp");
  return WifiLight_RGBWLD316_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBWLD316_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD316 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBWLD316_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW LD316 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction, may be doing it after wb more ok
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  ##########################################
  # sat is spread by 10% so there is room
  # for a smoth switch to white and adapt to 
  # higher brightness of white led
  ##########################################  

  $sat = ($sat * 1.1) -10;
  my $wl = ($sat<0)?$sat * -1:0;
  $sat = ($sat<0)?0:$sat;

  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # convert to device 4 channels (remaining r,g,b after substract white, white, rgb)
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my $msg;

  ##########################################
  # experimental white temp adjustment
  # G - 50%
  # B - 04%
  # sat is spread by 10% so there is room
  # for a smoth switch to white and adapt to 
  # higher brightness of whte led
  ##########################################

  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  # rgb mode
  if (($val > 0) && ($wl == 0)) 
  {
    #replace the removed part of white light and apply white balance
    $rr += int(($white * $wr) + 0.5);
    $rg += int(($white * $wg) + 0.5);
    $rb += int(($white * $wb) + 0.5);

    #new proto 0x56, r, g, b, white level, f0 (color) || 0f (white), 0xaa (terminator)
    $msg = sprintf("%c%c%c%c%c%c%c", 0x56, $rr, $rg, $rb, 0x00, 0xF0, 0xAA);
  }
  elsif ($wl > 0)
  {
    #smoth brightness adaption of white led
    my $wo = $gammaVal - ($gammaVal * (10-$wl) * 0.08); #0.07
    $wo = int(0.5 + ($wo * 2.55));
    $msg = sprintf("%c%c%c%c%c%c%c", 0x56, 0, 0, 0, $wo, 0x0F, 0xAA);
  }
  else
  {
    $msg = sprintf("%c%c%c%c%c%c%c", 0x56, 0, 0, 0, 0x00, 0xF0, 0xAA);
  }
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions LD382 aka Magic UFO
# with RGBW stripe (RGB and white)
#
#
###############################################################################

sub
WifiLight_RGBWLD382_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c", 0x71, 0x23, 0x94);
  my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382 set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBWLD382_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382 set off $ramp");
  return WifiLight_RGBWLD382_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBWLD382_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBWLD382_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW LD382 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # convert to device 4 channels (remaining r,g,b after substract white, white, rgb)
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my $msg = sprintf("%c%c%c%c%c%c%c", 0x31, $rr, $rg, $rb, $white, 0x00, 0x00);
  #add checksum
  $msg = WifiLight_RGBWLD382_Checksum($ledDevice, $msg);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

sub
WifiLight_RGBWLD382_Checksum(@)
{
  my ($ledDevice, $msg) = @_;
  my $c = 0;
  foreach my $w (split //, $msg)
  {
    $c += ord($w);
  }
  $c %= 0x100;
  $msg .= sprintf("%c", $c);
  return $msg;
}

###############################################################################
#
# device specific controller functions LD382 aka Magic UFO
# with RGB stripe (mixed white)
#
#
###############################################################################

sub
WifiLight_RGBLD382_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c", 0x71, 0x23, 0x94);
  my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382 set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBLD382_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382 set off $ramp");
  return WifiLight_RGBLD382_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLD382_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBLD382_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LD382 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # convert to device 4 channels (remaining r,g,b after substract white, white, rgb)
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  #replace the removed part of white light and apply white balance
  $rr += int(($white * $wr) + 0.5);
  $rg += int(($white * $wg) + 0.5);
  $rb += int(($white * $wb) + 0.5);

  my $msg = sprintf("%c%c%c%c%c%c%c", 0x31, $rr, $rg, $rb, 0x00, 0x00, 0x00);
  #add checksum
  $msg = WifiLight_RGBWLD382_Checksum($ledDevice, $msg);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions LD382A aka Magic UFO
# with RGBW stripe (RGB and white)
# LD382A is a LD382 with fw 1.0.6
#
###############################################################################

sub
WifiLight_RGBWLD382A_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c%c", 0x71, 0x23, 0x0F, 0xA3);
  # my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382A set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBWLD382A_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382A set off $ramp");
  return WifiLight_RGBWLD382A_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBWLD382A_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW LD382A dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBWLD382A_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW LD382A set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # convert to device 4 channels (remaining r,g,b after substract white, white, rgb)
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my $msg = sprintf("%c%c%c%c%c%c%c", 0x31, $rr, $rg, $rb, $white, 0x00, 0x0F);
  #add checksum
  $msg = WifiLight_RGBWLD382_Checksum($ledDevice, $msg);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions LD382A aka Magic UFO
# with RGB stripe (mixed white)
# LD382A is a LD382 with fw 1.0.6
#
###############################################################################

sub
WifiLight_RGBLD382A_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c%c", 0x71, 0x23, 0x0F, 0xA3);
  # my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382A set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBLD382A_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382A set off $ramp");
  return WifiLight_RGBLD382A_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLD382A_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LD382A dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBLD382A_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LD382A set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # convert to device 4 channels (remaining r,g,b after substract white, white, rgb)
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  #replace the removed part of white light and apply white balance
  $rr += int(($white * $wr) + 0.5);
  $rg += int(($white * $wg) + 0.5);
  $rb += int(($white * $wb) + 0.5);

  my $msg = sprintf("%c%c%c%c%c%c%c", 0x31, $rr, $rg, $rb, 0x00, 0x00, 0x0F);
  #add checksum
  $msg = WifiLight_RGBWLD382_Checksum($ledDevice, $msg);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions RGB LW12
# LED Stripe controller LW12
#
#
###############################################################################

sub
WifiLight_RGBLW12_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c", 0xCC, 0x23, 0x33);
  my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  my $receiver;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  # WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

#TODO set physical off: my $off = sprintf("%c%c%c", 0xCC, 0x24, 0x33);
sub
WifiLight_RGBLW12_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 set off $ramp");
  return WifiLight_RGBLW12_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLW12_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBLW12_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LW12 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];
  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  #new style converter with white point correction
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  #replace the removed part of white light and apply white balance
  $rr += int(($white * $wr) + 0.5);
  $rg += int(($white * $wg) + 0.5);
  $rb += int(($white * $wb) + 0.5);
  my $msg = sprintf("%c%c%c%c%c", 0x56, $rr, $rg, $rb, 0xAA);

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions RGB LW12 HX001 Version
# LED Stripe controller LW12
#
#
###############################################################################

sub
WifiLight_RGBLW12HX_On(@)
{
  my ($ledDevice, $ramp) = @_;
  # my $delay = 50;
  # my $on = sprintf("%c%c%c", 0xCC, 0x23, 0x33);
  # my $msg = sprintf("%c%c%c%c%c", 0x56, 0, 0, 0, 0xAA);
  # my $receiver;
  # WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  # WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12HX set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBLW12HX_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12HX set off $ramp");
  return WifiLight_RGBLW12HX_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLW12HX_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBHX LW12 dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBLW12HX_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LW12 set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);

  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];
  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  #new style converter with white point correction
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  #replace the removed part of white light and apply white balance
  $rr += int(($white * $wr) + 0.5);
  $rg += int(($white * $wg) + 0.5);
  $rb += int(($white * $wb) + 0.5);

  my $on = ($gammaVal > 0)?1:0;
  my $dim = 100;

  # supported by ichichich
  my @sendData = (0x9D, 0x62, 0x00, 0x01, 0x01, $on, $dim, $rr, $rg, $rb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00);
  my $chkSum = 0xFF;
  $chkSum += $_ for @sendData[3, 5..9];
  unless ($chkSum == 0)
  {
    $chkSum %= 0xFF;
    $chkSum = 0xFF if ($chkSum == 0);
  }
  push (@sendData, $chkSum);
  for (my $i=2; $i<11; $i++)
  {
    my $h = ($sendData[$i] & 0xF0) + ($sendData[21-$i] >> 4);
    my $l = (($sendData[$i] & 0x0F) << 4) + ($sendData[21-$i] & 0x0F);

    $sendData[$i] = $h;
    $sendData[21-$i] = $l;
  } 
  my $msg = pack('C*', @sendData);
  # $dbgStr = unpack("H*", $msg);
  # print "lw12HX $dbgStr \n";

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions RGB LW12 FC Version
# LED Stripe controller LW12
#
#
###############################################################################

sub
WifiLight_RGBLW12FC_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my $delay = 50;
  my $on = sprintf("%c%c%c%c%c%c%c%c%c", 0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF);
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12FC set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_RGBLW12FC_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12FC set off $ramp");
  return WifiLight_RGBLW12FC_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBLW12FC_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LW12FC dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_RGBLW12FC_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB LW12FC set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);

  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];
  # color cast correction
  my $h = $ledDevice->{helper}->{COLORMAP}[$hue]; 

  # new style converter with white point correction
  my ($rr, $rg, $rb, $white) = WifiLight_HSV2fourChannel($h, $sat, $gammaVal);
  my ($wr, $wg, $wb) = split(',', AttrVal($ledDevice->{NAME}, 'whitePoint', '1, 1, 1'));
  # replace the removed part of white light and apply white balance
  $rr += int(($white * $wr) + 0.5);
  $rg += int(($white * $wg) + 0.5);
  $rb += int(($white * $wb) + 0.5);

  my $on = ($gammaVal > 0)?1:0;
  my $dim = 100;

  my $msg = sprintf("%c%c%c%c%c%c%c%c%c", 0x7E, 0x07, 0x05, 0x03, $rr, $rg, $rb, 0x00, 0xEF);
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable
  $ledDevice->{helper}->{llLock} += 1;
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

###############################################################################
#
# device specific controller functions White SENGLED
# E27 LED Bulb with 
#
#
###############################################################################

sub
WifiLight_WhiteSENGLED_On(@)
{
  my ($ledDevice, $ramp) = @_;
  # my $delay = 50;
  # my $on = sprintf("%c%c%c%c%c%c%c%c%c", 0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF);
  # my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  # WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} White SENGLED set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 100, undef);
}

sub
WifiLight_WhiteSENGLED_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} White SENGLED set off $ramp");
  return WifiLight_WhiteSENGLED_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_WhiteSENGLED_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  # my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  # my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} White SENGLED dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, 0, 0, $level, $ramp, $flags, 100, undef);
}

sub
WifiLight_WhiteSENGLED_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val, $isLast) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 50;

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} White SENGLED set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);

  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];
  
  my @remote = split(/\./, $ledDevice->{helper}->{SOCKET}->peerhost());

  # intro
  my $msg = sprintf("%c%c%c%c%c", 0x0d, 0x00, 0x02, 0x00, 0x01);
  # sender, lazy 0x00
  $msg .= sprintf("%c%c%c%c", 0x00, 0x00, 0x00, 0x00);
  # destinations
  $msg .= sprintf("%c%c%c%c", $remote[0], $remote[1], $remote[2], $remote[3] );
  # sender, lazy 0x00
  $msg .= sprintf("%c%c%c%c", 0x00, 0x00, 0x00, 0x00);
  # destinations
  $msg .= sprintf("%c%c%c%c", $remote[0], $remote[1], $remote[2], $remote[3] );
  # intro 2
  $msg .= sprintf("%c%c%c%c%c%c", 0x01, 0x00, 0x01, 0x00, 0x00, 0x00);
  # cmd level
  $msg .= sprintf("%c%c", $gammaVal, 0x64);
  
  # for safety of tranmission (udp): repeat cmd if its stand-alone or first or last in transition
  my $repeat = ($isLast)?3:1;
  for (my $i=0; $i<$repeat; $i++)
  {
    # lock ll queue to prevent a bottleneck within llqueue
    # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
    # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
    $ledDevice->{helper}->{llLock} += 1;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
    # unlock ll queue after complete cmd is send
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
  }
  
  return undef;
}

###############################################################################
#
# device specific controller functions RGB
# LED Stripe or bulb, no white, controller V2
#
###############################################################################

sub
WifiLight_RGB_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LED slot $ledDevice->{SLOT} pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGB_UnPair(@)
{
  my ($ledDevice) = @_;
  my $numSeconds = 8;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB LED slot $ledDevice->{SLOT} unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGB_Sync(@)
{
  my ($ledDevice) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  $ledDevice->{helper}->{whiteLevel} =9; 
  $ledDevice->{helper}->{colorLevel} =9;
  $ledDevice->{helper}->{colorValue} =127; 
  $ledDevice->{helper}->{mode} =2; # mode 0: off, 1: mixed "white", 2: color
 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, 500); # on
  for (my $i = 0; $i < 22; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode up (to "pure white" ;-) 
  }
  for (my $i = 0; $i < 10; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up (to "pure white" ;-) 
  }
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20\x7F\x55", $receiver, $delay); # color yellow (auto jump to mode 2)
  for (my $i = 0; $i < 10; $i++) {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up (yellow max brightness) 
  }

  WifiLight_setHSV_Readings($ledDevice, 60, 100, 100) if $init_done;

  return undef;
}

sub
WifiLight_RGB_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "40,100,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 500, undef);
}

sub
WifiLight_RGB_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGB_Dim($ledDevice, 0, $ramp, '');
  #TODO remove if tested
  #return WifiLight_HSV_Transition($ledDevice, 0, 100, 0, $ramp, undef, 500, undef);
}

sub
WifiLight_RGB_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 500, undef);
}

sub
WifiLight_RGB_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set h:$hue, s:$sat, v:$val"); 
  $sat = 100;
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = WifiLight_RGBW1_ColorConverter($ledDevice, $hue, $sat, $val);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGB slot $ledDevice->{SLOT} set levels: $cv, $cl, $wl");
  return WifiLight_RGB_setLevels($ledDevice, $cv, $cl, $wl);
}

sub
WifiLight_RGB_setLevels(@)
{
  my ($ledDevice, $cv, $cl, $wl) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;
  my $lock = 0;

  # mode 0: off, 1: mixed "white", 2: color
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || ($ledDevice->{helper}->{colorLevel} != $cl) || ($ledDevice->{helper}->{whiteLevel} != $wl))
  {
    $ledDevice->{helper}->{llLock} += 1;
    $lock = 1;
  }
  # need to touch color value (only if visible) or color level ?
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || $ledDevice->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 2;
    }
    elsif ($ledDevice->{helper}->{mode} == 1)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{mode} = 2;
    }
    else
    {
      $ledDevice->{helper}->{colorValue} = $cv;
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
    }
    # cl decrease
    if ($ledDevice->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active we can must entirely switch off
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
        $ledDevice->{helper}->{colorLevel} = 0;
        $ledDevice->{helper}->{mode} = 0;
      }
    }
    # cl inrease
    if ($ledDevice->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
        $ledDevice->{helper}->{colorLevel} = $i + 1;
      }
    }
  }
  # unlock ll queue
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1) if $lock;
  return undef;
}

###############################################################################
#
# device specific controller functions RGBW1 
# LED Stripe with extra white led, controller V2, bridge V2|bridge V3
#
#
###############################################################################

sub
WifiLight_RGBW1_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 LED slot $ledDevice->{SLOT} pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW1_UnPair(@)
{
  my ($ledDevice) = @_;
  my $numSeconds = 8;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 LED slot $ledDevice->{SLOT} unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = "\x25\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW1_Sync(@)
{
  my ($ledDevice) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 250;

  $ledDevice->{helper}->{whiteLevel} =9; 
  $ledDevice->{helper}->{colorLevel} =9;
  $ledDevice->{helper}->{colorValue} =170; 
  $ledDevice->{helper}->{mode} =3; # mode 0: c:off, w:off; 1: c:on, w:off; 2: c:off, w:on; 3: c:on, w:on

  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, 500); # on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20\xAA\x55", $receiver, $delay); # color red (auto jump to mode 1 except we are mode 3)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (now we are for sure in mode 1)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #1
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #2
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #3
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #4
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #5
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #6
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #7
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #8 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #9 (highest dim-level color red)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (pure white) 
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #1
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #2
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #3
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #4
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #5
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #6
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #7
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #8
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # dim up #9 (highest dim-level white)
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (white and red at highest level: bright warm light) 

  WifiLight_setHSV_Readings($ledDevice, 0, 50, 100) if $init_done;

  return undef;
}

sub
WifiLight_RGBW1_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 1000, undef);
}

sub
WifiLight_RGBW1_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGBW1_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_RGBW1_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 1000, undef);
}

sub
WifiLight_RGBW1_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set h:$hue, s:$sat, v:$val"); 
  WifiLight_setHSV_Readings($ledDevice, $hue, $sat, $val);
  # convert to device specs
  my ($cv, $cl, $wl) = WifiLight_RGBW1_ColorConverter($ledDevice, $hue, $sat, $val);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW1 slot $ledDevice->{SLOT} set levels: $cv, $cl, $wl");
  return WifiLight_RGBW1_setLevels($ledDevice, $cv, $cl, $wl);
}

sub
WifiLight_RGBW1_setLevels(@)
{
  my ($ledDevice, $cv, $cl, $wl) = @_;
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 250;
  my $lock = 0;

  # need to touch color value or color level?
  # yes
  # is color visible ? (we are in mode 1 or 3)
  #   yes: adjust color!, requ level = 1 if cl = 0; new level 0 ? yes: mode 0 if wl == 0 else Mode = 1 (if coming from 0 or 1 then wl =1)
  #   no:
  #     will we need color ?
  #       yes: go into mode #1, (cl jumps to 1)

  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || ($ledDevice->{helper}->{colorLevel} != $cl) || ($ledDevice->{helper}->{whiteLevel} != $wl))
  {
    $ledDevice->{helper}->{llLock} += 1;
    $lock = 1;
  }

  # need to touch color value (only if visible) or color level ?
  if ((($ledDevice->{helper}->{colorValue} != $cv) && ($cl > 0)) || $ledDevice->{helper}->{colorLevel} != $cl)
  {
    # if color all off switch on
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down: 3 > 2 || 2 > 1
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down: 2 > 1 || 1 > 1
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 1;
    }
    elsif ($ledDevice->{helper}->{mode} == 2)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up: 2 > 3
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
      $ledDevice->{helper}->{colorLevel} = 1;
      $ledDevice->{helper}->{mode} = 3;
    }
    else
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x20".chr($cv)."\x55", $receiver, $delay); # set color
      $ledDevice->{helper}->{colorValue} = $cv;
    }

    # color level decrease
    if ($ledDevice->{helper}->{colorLevel} > $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i > $cl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{colorLevel} = $i - 1;
      }
      if ($cl == 0)
      {
        # need to switch off color
        # if no white is required and no white is active switch off
        if (($wl == 0) && ($ledDevice->{helper}->{mode} == 1))
        {
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
          $ledDevice->{helper}->{colorLevel} = 0;
          $ledDevice->{helper}->{mode} = 0;
        }
        # if white is required, goto mode 2: pure white
        if (($wl > 0) || ($ledDevice->{helper}->{mode} == 2) ||  ($ledDevice->{helper}->{mode} == 3))
        {
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay) if ($ledDevice->{helper}->{mode} == 1) ; # mode up
          WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay) if ($ledDevice->{helper}->{mode} == 3) ; # mode down
          $ledDevice->{helper}->{colorLevel} = 0;
          $ledDevice->{helper}->{whiteLevel} = 1 if ($ledDevice->{helper}->{mode} == 1);
          $ledDevice->{helper}->{mode} = 2;
        }
      }
    }
    if ($ledDevice->{helper}->{colorLevel} < $cl)
    {
      for (my $i=$ledDevice->{helper}->{colorLevel}; $i < $cl; $i++)
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
        $ledDevice->{helper}->{colorLevel} = $i + 1;
      }
    }
  }
  # need to adjust white level ?
  if ($ledDevice->{helper}->{whiteLevel} != $wl)
  {
    # white off but need adjustment ? set it on..
    # color processing is finished, so if we are in mode 0, no color required. go to mode 2: pure white
    if ($ledDevice->{helper}->{mode} == 0)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x22\x00\x55", $receiver, $delay); # switch on
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (3 -> 2 || 2 -> 1)
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (2 -> 1 || 1 -> 1)
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (1 -> 2)
      $ledDevice->{helper}->{whiteLevel} = 1;
      $ledDevice->{helper}->{mode} = 2;
    }
    # color processing is finished, so if we are at mode 1 color is required. go to mode 2
    if ($ledDevice->{helper}->{mode} == 1)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (1 -> 2)
      $ledDevice->{helper}->{whiteLevel} = 1;
      $ledDevice->{helper}->{mode} = 2; 
    }
    # temporary go to mode 2 while maintain white level
    if ($ledDevice->{helper}->{mode} == 3)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (3 -> 2)
      $ledDevice->{helper}->{mode} = 2; 
    }
    # white level inrease
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i < $wl; $i++)
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x23\x00\x55", $receiver, $delay); # brightness up
      $ledDevice->{helper}->{whiteLevel} = $i + 1;
    }
    # white level decrease
    if ($ledDevice->{helper}->{whiteLevel} > $wl)
    {
      for (my $i=$ledDevice->{helper}->{whiteLevel}; $i > $wl; $i--) 
      {
        WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x24\x00\x55", $receiver, $delay); # brightness down
        $ledDevice->{helper}->{whiteLevel} = $i - 1;
      }
    }

    # assume we are at mode 2, finishing to correct mode
    if (($wl == 0) && ($cl == 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x21\x00\x55", $receiver, $delay); # switch off
      $ledDevice->{helper}->{whiteLevel} = 0;
      $ledDevice->{helper}->{mode} = 0;
    }
    if (($wl == 0) && ($cl > 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x28\x00\x55", $receiver, $delay); # mode down (2 -> 1)
      $ledDevice->{helper}->{whiteLevel} = 0;
      $ledDevice->{helper}->{mode} = 1; 
    }
    if (($wl > 0) && ($cl > 0))
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x27\x00\x55", $receiver, $delay); # mode up (2 -> 3)
      $ledDevice->{helper}->{mode} = 3; 
    }
  }
  # unlock ll queue
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1) if $lock;
  return undef;
}

sub
WifiLight_RGBW1_ColorConverter(@)
{
  my ($ledDevice, $h, $s, $v) = @_;
  my $color = $ledDevice->{helper}->{COLORMAP}[$h % 360];
  
  # there are 0..9 dim level, setup correction
  my $valueSpread = 100/9;
  my $totalVal = int(($v / $valueSpread) +0.5);
  # saturation 100..50: color full, white increase. 50..0 white full, color decrease
  my $colorVal = ($s >= 50) ? $totalVal : int(($s / 50 * $totalVal) +0.5);
  my $whiteVal = ($s >= 50) ? int(((100-$s) / 50 * $totalVal) +0.5) : $totalVal;
  return ($color, $colorVal, $whiteVal);
}

###############################################################################
#
# device specific functions RGBW2 bulb 
# RGB white, only bridge V3
#
#
###############################################################################

sub
WifiLight_RGBW2_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 3 if (($numSeconds || 0) == 0);
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: pair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW2_UnPair(@)
{
  my ($ledDevice, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
  }
  return undef;
}

sub
WifiLight_RGBW2_Sync(@)
{
  my ($ledDevice) = @_;
  # force new settings
  $ledDevice->{helper}->{mode} = -1; 
  $ledDevice->{helper}->{colorValue} = -1; 
  $ledDevice->{helper}->{colorLevel} = -1;
  $ledDevice->{helper}->{whiteLevel} = -1;
  return undef;
}

sub
WifiLight_RGBW2_On(@)
{
  my ($ledDevice, $ramp) = @_;
  my ($h, $s, $v) = split(',', AttrVal($ledDevice->{NAME}, "defaultColor", "0,0,100"));
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} set on ($h, $s, $v) $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $v, $ramp, '', 200, undef);
}

sub
WifiLight_RGBW2_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} set off $ramp");
  return WifiLight_RGBW2_Dim($ledDevice, 0, $ramp, '');
  #TODO remove if tested
  #return WifiLight_HSV_Transition($ledDevice, 0, 0, 0, $ramp, undef, 500, undef);
}

sub
WifiLight_RGBW2_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} dim $level $ramp ". $flags || ''); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 200, undef);
}

sub
WifiLight_RGBW2_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val, $isLast) = @_;
  my ($cl, $wl);

  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;
  my $cv = $ledDevice->{helper}->{COLORMAP}[$hue % 360];

  # apply gamma correction
  my $gammaVal = $ledDevice->{helper}->{GAMMAMAP}[$val];

  # mode 0 = off, 1 = color, 2 = white
  # brightness 2..27 (x02..x1b) | 25 
  my $cf = 100 / 26;
  my $cb = int(($gammaVal / $cf) + 0.5);
  $cb += ($cb > 0)?1:0;

  if ($sat < 20) 
  {
    $wl = $cb;
    $cl = 0;
    WifiLight_setHSV_Readings($ledDevice, $hue, 0, $val);
  }
  else
  {
    $cl = $cb;
    $wl = 0;
    WifiLight_setHSV_Readings($ledDevice, $hue, 100, $val);
  }

  return WifiLight_RGBW2_setLevelsFast($ledDevice, $receiver, $cv, $cl, $wl) unless ($isLast);
  return WifiLight_RGBW2_setLevelsSafe($ledDevice, $receiver, $cv, $cl, $wl);
}

# repeatly send out a full size cmd 
# the last cmd in a transition or if it is stand alone
sub
WifiLight_RGBW2_setLevelsSafe(@)
{
  my ($ledDevice, $receiver, $cv, $cl, $wl) = @_;
  my $delay = 100;

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  my @bulbCmdsOff = ("\x46", "\x48", "\x4A", "\x4C");
  my @bulbCmdsWT = ("\xC5", "\xC7", "\xC9", "\xCB");

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} set safe levels");
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} lock queue ".$ledDevice->{helper}->{llLock});

  my @cmd = ();
  
  # about switching off. dim to prevent a flash if switched on again
  
  if (($wl == 0) && ($cl == 0) && ($ledDevice->{helper}->{mode} != 0))
  {
    $ledDevice->{helper}->{llLock} += 1; # lock ...
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay); # group on
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E\x02\x55", $receiver, $delay); # brightness
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1); # ... unlock
  }

  if (($wl == 0) && ($cl == 0))
  {
    push (@cmd, @bulbCmdsOff[$ledDevice->{SLOT} -5]."\x00\x55");
    $ledDevice->{helper}->{whiteLevel} = 0;
    $ledDevice->{helper}->{colorLevel} = 0;
    $ledDevice->{helper}->{mode} = 0; # group off
  }
  elsif ($wl > 0)
  {
    push (@cmd, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55");
    push (@cmd, @bulbCmdsWT[$ledDevice->{SLOT} -5]."\x00\x55");
    push (@cmd, "\x4E".chr($wl)."\x55");
    $ledDevice->{helper}->{whiteLevel} = $wl;
    $ledDevice->{helper}->{colorLevel} = 0;
    $ledDevice->{helper}->{mode} = 2; # white
  }
  elsif ($cl > 0)
  {
    push (@cmd, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55");
    push (@cmd, "\x40".chr($cv)."\x55"); # color
    push (@cmd, "\x4E".chr($cl)."\x55"); # brightness
    $ledDevice->{helper}->{whiteLevel} = 0;
    $ledDevice->{helper}->{colorLevel} = $cl;
    $ledDevice->{helper}->{colorValue} = $cv;
    $ledDevice->{helper}->{mode} = 1; # color
  }

  # repeat it three times
  for (my $i=0; $i<3; $i++)
  {
    # lock ll queue to prevent a bottleneck within llqueue
    # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
    # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
    $ledDevice->{helper}->{llLock} += 1;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $_, $receiver, $delay) foreach (@cmd);
    # unlock ll queue after complete cmd is send
    WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
  }

  return undef;
}

# classic optimized version, used by fast color transitions
sub
WifiLight_RGBW2_setLevelsFast(@)
{
  my ($ledDevice, $receiver, $cv, $cl, $wl) = @_;
  my $delay = 100;

  my @bulbCmdsOn = ("\x45", "\x47", "\x49", "\x4B");
  my @bulbCmdsOff = ("\x46", "\x48", "\x4A", "\x4C");
  my @bulbCmdsWT = ("\xC5", "\xC7", "\xC9", "\xCB");

  return if (($ledDevice->{helper}->{colorValue} == $cv) && ($ledDevice->{helper}->{colorLevel} == $cl) && ($ledDevice->{helper}->{whiteLevel} == $wl));
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} RGBW2 slot $ledDevice->{SLOT} lock queue ".$ledDevice->{helper}->{llLock});

  if (($wl == 0) && ($cl == 0) && ($ledDevice->{helper}->{mode} != 0))
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOff[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay);
    $ledDevice->{helper}->{whiteLevel} = 0;
    $ledDevice->{helper}->{colorLevel} = 0;
    $ledDevice->{helper}->{mode} = 0; # group off
  }
  else
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay); # group on
    # WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay) if (($wl > 0) || ($cl > 0)); # group on
    if (($wl > 0) && ($ledDevice->{helper}->{mode} == 2)) # already white
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($wl)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{whiteLevel} != $wl); # brightness
    }
    elsif (($wl > 0) && ($ledDevice->{helper}->{mode} != 2)) # not white
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsWT[$ledDevice->{SLOT} -5]."\x00\x55", $receiver, $delay); # white
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($wl)."\x55", $receiver, $delay); # brightness
      $ledDevice->{helper}->{mode} = 2; # white
    }
    elsif (($cl > 0) && ($ledDevice->{helper}->{mode} == 1)) # already color
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($cl)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{colorLevel} != $cl); # brightness
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x40".chr($cv)."\x55", $receiver, $delay) if ($ledDevice->{helper}->{colorValue} != $cv); # color
    }
    elsif (($cl > 0) && ($ledDevice->{helper}->{mode} != 1)) # not color
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x40".chr($cv)."\x55", $receiver, $delay); # color
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x4E".chr($cl)."\x55", $receiver, $delay); # brightness
      $ledDevice->{helper}->{mode} = 1; # color
    }
    $ledDevice->{helper}->{colorValue} = $cv;
    $ledDevice->{helper}->{colorLevel} = $cl;
    $ledDevice->{helper}->{whiteLevel} = $wl;
  }
  # unlock ll queue after complete cmd is send
  WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
  return undef;
}

###############################################################################
#
# device specific functions white bulb 
# warm white / cold white with dim, bridge V2|bridge V3
#
#
###############################################################################

sub
WifiLight_White_Pair(@)
{
  my ($ledDevice, $numSeconds) = @_;
  $numSeconds = 1 if !(defined($numSeconds));
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: pair $numSeconds");
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 500, undef, undef);
  }
  return undef;
}

sub
WifiLight_White_UnPair(@)
{
  my ($ledDevice, $numSeconds, $releaseFromSlot) = @_;
  $numSeconds = 5;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: unpair $numSeconds"); 
  # find my slot and get my group-all-on cmd
  my $ctrl = @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55";
  for (my $i = 0; $i < $numSeconds; $i++)
  { 
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
    WifiLight_HighLevelCmdQueue_Add($ledDevice, undef, undef, undef, $ctrl, 250, undef, undef);
  }
  return undef;
}

sub
WifiLight_White_Sync(@)
{
  my ($ledDevice) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsFB = ("\xB8", "\xBD", "\xB7", "\xB2");
  
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  $ledDevice->{helper}->{whiteLevel} =11; 

  Log3 ($ledDevice, 3, "$ledDevice->{NAME}, $ledDevice->{LEDTYPE} at $ledDevice->{CONNECTION}, slot $ledDevice->{SLOT}: sync"); 

  WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
  WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsFB[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # full brightness

  WifiLight_setHSV_Readings($ledDevice, 0, 0, 100) if $init_done;

  return undef;
}

sub
WifiLight_White_On(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} set on $ramp"); 
  return WifiLight_HSV_Transition($ledDevice, 0, 0, 100, $ramp, '', 500, undef);
}

sub
WifiLight_White_Off(@)
{
  my ($ledDevice, $ramp) = @_;
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} set off $ramp"); 
  return WifiLight_RGBW2_Dim($ledDevice, 0, $ramp, '');
}

sub
WifiLight_White_Dim(@)
{
  my ($ledDevice, $level, $ramp, $flags) = @_;
  my $h = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  my $s = ReadingsVal($ledDevice->{NAME}, "saturation", 0);
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} white slot $ledDevice->{SLOT} dim $level $ramp $flags"); 
  return WifiLight_HSV_Transition($ledDevice, $h, $s, $level, $ramp, $flags, 300, undef);
}

# only val supported, 
# TODO hue will become colortemp
sub
WifiLight_White_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my $wlStep = (100 / 11);
  WifiLight_setHSV_Readings($ledDevice, 0, 0, $val);
  $val = int(($val / $wlStep) +0.5);
  WifiLight_White_setLevels($ledDevice, undef, $val);
  
  return undef;
}

sub
WifiLight_White_setLevels(@)
{
  my ($ledDevice, $cv, $wl) = @_;
  my @bulbCmdsOn = ("\x38", "\x3D", "\x37", "\x32");
  my @bulbCmdsOff = ("\x3B", "\x33", "\x3A", "\x36");
  my @bulbCmdsFull = ("\xB8", "\xBD", "\xB7", "\xB2");
  my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
  my $delay = 100;

  # alert that dump receiver, give it a extra wake up call 
  if ($ledDevice->{helper}->{whiteLevel} != $wl) 
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay);
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay);
  }
  
  if ($ledDevice->{helper}->{whiteLevel} > $wl)
  {
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i > $wl; $i--) 
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x34\x00\x55", $receiver, $delay); # brightness down
      $ledDevice->{helper}->{whiteLevel} = $i - 1;
    }
    if ($wl == 0)
    {
      # special precaution, giving extra downsteps to do a sync each time you switch off
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x34\x00\x55", $receiver, $delay); # brightness down
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x34\x00\x55", $receiver, $delay); # brightness down
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x34\x00\x55", $receiver, $delay); # brightness down
      WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOff[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group off
    }
  }
   
  if ($ledDevice->{helper}->{whiteLevel} < $wl)
  {
    $ledDevice->{helper}->{whiteLevel} = 1 if ($ledDevice->{helper}->{whiteLevel} == 0);
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsOn[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay); # group on
    for (my $i=$ledDevice->{helper}->{whiteLevel}; $i < $wl; $i++) 
    {
      WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x3C\x00\x55", $receiver, $delay); # brightness up
      $ledDevice->{helper}->{whiteLevel} = $i + 1;
    }
    WifiLight_LowLevelCmdQueue_Add($ledDevice, @bulbCmdsFull[$ledDevice->{SLOT} -1]."\x00\x55", $receiver, $delay) if ($ledDevice->{helper}->{whiteLevel} == 11);
  }
  return undef;
}

###############################################################################
#
# device specific controller functions LK35 (Easy RGB(W)-Controller)
# device Range 0x00 to 0x7F
#
#
###############################################################################

sub
WifiLight_LK35_On(@)
{
  my ($ledDevice, $ramp) = @_;
  
  my $delay = 0;
  my $on = pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x02, 0x12, 0xAB, 0x00, 0xAA, 0xAA );
  my $receiver;
  
  $on = WifiLight_LK35_Checksum($ledDevice, $on);
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $on, $receiver, $delay);
  
  WifiLight_setLK35_Readings($ledDevice, $ledDevice->{helper}->{rLevel}, $ledDevice->{helper}->{gLevel}, $ledDevice->{helper}->{bLevel}, $ledDevice->{helper}->{wLevel}, $ledDevice->{helper}->{brightness});
}

sub
WifiLight_LK35_Off(@)
{
  
  my ($ledDevice, $ramp) = @_;
  
  my $delay = 50;
  my $off = pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x02, 0x12, 0xA9, 0x00, 0xAA, 0xAA );
  my $receiver;
  
  $off = WifiLight_LK35_Checksum($ledDevice, $off);
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $off, $receiver, $delay);
  WifiLight_setLK35_Readings($ledDevice, 0, 0, 0, 0, 0);  
}

sub
WifiLight_LK35_Dim(@)
{
  my ($ledDevice, $brightness, $ramp) = @_;
  
  my $delay = 50;
  my $dim = pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x23, $brightness, 0x00, 0xAA, 0xAA );
  my $receiver;
  
  $dim = WifiLight_LK35_Checksum($ledDevice, $dim);
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $dim, $receiver, $delay);
  $ledDevice->{helper}->{brightness} = $brightness;
  WifiLight_setLK35_Readings($ledDevice, $ledDevice->{helper}->{rLevel}, $ledDevice->{helper}->{gLevel}, $ledDevice->{helper}->{bLevel}, $ledDevice->{helper}->{wLevel}, $brightness);  
}



sub
WifiLight_LK35_setRGB(@)
{
  my ($ledDevice, $r, $g, $b) = @_;
  my $receiver;
  my $delay = 0;
  my $msg = '';

  
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} LK35 set r:$r, g:$g, b:$b"); 
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x18, $r/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{rLevel} != $r);
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x19, $g/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{gLevel} != $g);
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x20, $b/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{bLevel} != $b);

  $ledDevice->{helper}->{rLevel} = $r;
  $ledDevice->{helper}->{gLevel} = $g;
  $ledDevice->{helper}->{bLevel} = $b;  

  WifiLight_setLK35_Readings($ledDevice, $ledDevice->{helper}->{rLevel}, $ledDevice->{helper}->{gLevel}, $ledDevice->{helper}->{bLevel}, $ledDevice->{helper}->{wLevel}, $ledDevice->{helper}->{brightness});
  
  
  # leave here if nothing to tell
  return unless $msg;
  
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

sub
WifiLight_LK35_setRGBW(@)
{
  my ($ledDevice, $r, $g, $b, $w) = @_;
  my $receiver;
  my $delay = 0;
  my $msg = '';

  
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} LK35 set r:$r, g:$g, b:$b"); 
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x18, $r/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{rLevel} != $r);
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x19, $g/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{gLevel} != $g);
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x20, $b/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{bLevel} != $b);
  $msg .= WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, 0x21, $w/2, 0x00, 0xAA, 0xAA)); #if ($ledDevice->{helper}->{bLevel} != $b);

  
  $ledDevice->{helper}->{rLevel} = $r;
  $ledDevice->{helper}->{gLevel} = $g;
  $ledDevice->{helper}->{bLevel} = $b;
  $ledDevice->{helper}->{wLevel} = $w;  

  WifiLight_setLK35_Readings($ledDevice, $ledDevice->{helper}->{rLevel}, $ledDevice->{helper}->{gLevel}, $ledDevice->{helper}->{bLevel}, $ledDevice->{helper}->{wLevel}, $ledDevice->{helper}->{brightness});
  
  
  # leave here if nothing to tell
  return unless $msg;
  
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

sub
WifiLight_LK35_setColor(@)
{
  my ($ledDevice, $color, $value) = @_;
  my $receiver;
  my $delay = 0;
  my $msg = '';
  my $colorByte = 0x00; 
  
  if($color eq "R")
  {
	$colorByte = 0x18; 
	$ledDevice->{helper}->{rLevel} = $value;
  }
  elsif($color eq "G")
  {
	$colorByte = 0x19; 
	$ledDevice->{helper}->{gLevel} = $value;
  }
  elsif($color eq "B")
  {
	$colorByte = 0x20; 
	$ledDevice->{helper}->{bLevel} = $value;
  }
  elsif($color eq "W")
  {
	$colorByte = 0x21; 
	$ledDevice->{helper}->{wLevel} = $value;
  }


  Log3 ($ledDevice, 3, "$ledDevice->{NAME} LK35 set $color:$value"); 
  $msg = WifiLight_LK35_Checksum($ledDevice, pack('C*', 0x55, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x08, $colorByte, $value/2, 0x00, 0xAA, 0xAA));
  
  WifiLight_setLK35_Readings($ledDevice, $ledDevice->{helper}->{rLevel}, $ledDevice->{helper}->{gLevel}, $ledDevice->{helper}->{bLevel}, $ledDevice->{helper}->{wLevel}, $ledDevice->{helper}->{brightness});
  # leave here if nothing to tell
  return unless $msg;
  
  # lock ll queue to prevent a bottleneck within llqueue
  # in cases where the high level queue fills the low level queue (which should not be interrupted) faster then it is processed (send out)
  # this lock will cause the hlexec intentionally drop frames which can safely be done because there are further frames for processing avialable  
  $ledDevice->{helper}->{llLock} += 1;  
  WifiLight_LowLevelCmdQueue_Add($ledDevice, $msg, $receiver, $delay);
  # unlock ll queue
  return WifiLight_LowLevelCmdQueue_Add($ledDevice, "\x00", $receiver, 0, 1);
}

sub
WifiLight_LK35_Checksum(@)
{
  my ($ledDevice, $msg) = @_;
  
  my @byteStream = unpack('C*', $msg);
  my $l = @byteStream;
  my $c = 0;
  
  for (my $i=4; $i<($l-3); $i++) {
    $c += $byteStream[$i];
  }
  $c %= 0x100;
  $byteStream[$l -3]  = $c;
  $msg = pack('C*', @byteStream);
  return $msg;
}

sub
WifiLight_setLK35_Readings(@)
{
  my ($ledDevice, $r, $g, $b, $w, $brightness) = @_;
  readingsBeginUpdate($ledDevice);
  readingsBulkUpdate($ledDevice, "red", $r);
  readingsBulkUpdate($ledDevice, "green", $g);
  readingsBulkUpdate($ledDevice, "blue", $b);
  readingsBulkUpdate($ledDevice, "white", $w);
  readingsBulkUpdate($ledDevice, "brightness", $brightness);
  readingsBulkUpdate($ledDevice, "RGB", sprintf("%02X%02X%02X",$r,$g,$b));
  readingsBulkUpdate($ledDevice, "RGBW", sprintf("%02X%02X%02X%02X",$r,$g,$b,$w));
  readingsBulkUpdate($ledDevice, "state", "on") if ($r+$g+$b+$w+$brightness > 0);
  readingsBulkUpdate($ledDevice, "state", "off") if (($r+$g+$b+$w == 0) || ($w+$brightness == 0));
  readingsEndUpdate($ledDevice, 1);
}

###############################################################################
#
# device indepenent routines
#
###############################################################################

# dispatcher 
sub
WifiLight_setHSV(@)
{
  my ($ledDevice, $hue, $sat, $val, $isLast) = @_;
  return WifiLight_RGBWLD316_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD316'));
  return WifiLight_RGBWLD382_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382'));
  return WifiLight_RGBLD382_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382'));
  return WifiLight_RGBWLD382A_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGBW') && ($ledDevice->{CONNECTION} eq 'LD382A'));
  return WifiLight_RGBLD382A_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} eq 'LD382A'));
  return WifiLight_RGBLW12_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{CONNECTION} eq 'LW12');
  return WifiLight_RGBLW12HX_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{CONNECTION} eq 'LW12HX');
  return WifiLight_RGBLW12FC_setHSV($ledDevice, $hue, $sat, $val) if ($ledDevice->{CONNECTION} eq 'LW12FC');
  return WifiLight_WhiteSENGLED_setHSV($ledDevice, $hue, $sat, $val, $isLast) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} eq 'SENGLED'));
  return WifiLight_RGB_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
  return WifiLight_RGBW1_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq "RGBW1") && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
  return WifiLight_RGBW2_setHSV($ledDevice, $hue, $sat, $val, $isLast) if ($ledDevice->{LEDTYPE} eq "RGBW2");
  return WifiLight_White_setHSV($ledDevice, $hue, $sat, $val) if (($ledDevice->{LEDTYPE} eq 'White') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'));
  return undef;
}

# dispatcher
sub
WifiLight_processEvent(@)
{
  my ($ledDevice, $event, $progress) = @_;
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} processEvent: $event, progress: $progress") if defined($event);
  DoTrigger($ledDevice->{NAME}, "programm: $event $progress",0) if defined($event);
  return undef;
}

sub
WifiLight_HSV_Transition(@)
{
  my ($ledDevice, $hue, $sat, $val, $ramp, $flags, $delay, $event) = @_;
  my ($hueFrom, $satFrom, $valFrom, $timeFrom);
  
  # minimum stepwide
  my $defaultDelay = $delay;

  #TODO remove if tested
  #if (($ramp || 0) == 0)
  #{
  #  Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition without ramp routed to direct settings, hsv $hue, $sat, $val");
  #  $ledDevice->{helper}->{targetTime} = gettimeofday();
  #  return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, undef, undef, $ledDevice->{helper}->{targetTime});
  #}

  # if queue in progess set start vals to last cached hsv target, else set start to actual hsv
  if (@{$ledDevice->{helper}->{hlCmdQueue}} > 0)
  {
    $hueFrom = $ledDevice->{helper}->{targetHue};
    $satFrom = $ledDevice->{helper}->{targetSat};
    $valFrom = $ledDevice->{helper}->{targetVal};
    $timeFrom = $ledDevice->{helper}->{targetTime};
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} prepare start hsv transition (is cached) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }
  else
  {
    $hueFrom = $ledDevice->{READINGS}->{hue}->{VAL};
    $satFrom = $ledDevice->{READINGS}->{saturation}->{VAL};
    $valFrom = $ledDevice->{READINGS}->{brightness}->{VAL};
    $timeFrom = gettimeofday();
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} prepare start hsv transition (is actual) hsv $hueFrom, $satFrom, $valFrom, $timeFrom");
  }

  Log3 ($ledDevice, 4, "$ledDevice->{NAME} current HSV $hueFrom, $satFrom, $valFrom");
  Log3 ($ledDevice, 3, "$ledDevice->{NAME} set HSV $hue, $sat, $val with ramp: $ramp, flags: ". $flags);

  # if there is no ramp we dont need transition
  if (($ramp || 0) == 0)
  {
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition without ramp routed to direct settings, hsv $hue, $sat, $val");
    $ledDevice->{helper}->{targetTime} = $timeFrom;
    return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, 100, $event, $timeFrom);
  }

  # calculate the left and right turn length based
  # startAngle +360 -endAngle % 360 = counter clock
  # endAngle +360 -startAngle % 360 = clockwise
  my $fadeLeft = ($hueFrom + 360 - $hue) % 360;
  my $fadeRight = ($hue + 360 - $hueFrom) % 360;
  my $direction = ($fadeLeft <=> $fadeRight); # -1 = counterclock, +1 = clockwise
  $direction = ($direction == 0)?1:$direction; # in dupt cw
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} color rotation dev cc:$fadeLeft, cw:$fadeRight, shortest:$direction"); 
  $direction *= -1 if ($flags =~ m/.*[lL].*/); # reverse if long path desired (flag l or L is set)

  my $rotation = ($direction == 1)?$fadeRight:$fadeLeft; # angle of hue rotation in based on flags
  my $sFade = abs($sat - $satFrom);
  my $vFade = abs($val - $valFrom);
        
  my ($stepWide, $steps, $hueToSet, $hueStep, $satToSet, $satStep, $valToSet, $valStep);
  
  # fix if there is in fact no transition, blocks queue for given ramp time with actual hsv values
  if ($rotation == 0 && $sFade == 0 && $vFade == 0)
  {
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} hsv transition with unchaned settings, hsv $hue, $sat, $val, ramp $ramp"); 
    #TODO remove if tested 
    #WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $ramp * 1000, 0, $event, $timeFrom);
    
    $ledDevice->{helper}->{targetTime} = $timeFrom + $ramp;
    return WifiLight_HighLevelCmdQueue_Add($ledDevice, $hue, $sat, $val, undef, $delay, 100, $event, $timeFrom + $ramp);
  }

  if (($rotation >= $sFade) && ($rotation >= $vFade))
  {
    $stepWide = ($ramp * 1000 / $rotation); # how long is one step (set hsv) in ms based on hue
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (H>S||V) steps: $steps stepwide: $stepWide");  
  }
  elsif (($sFade  >= $rotation) && ($sFade  >= $vFade))
  {
    $stepWide = ($ramp * 1000 / $sFade); # how long is one step (set hsv) in ms based on sat
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (S>H||V) steps: $steps stepwide: $stepWide");  
  }
  else
  {
    $stepWide = ($ramp * 1000 / $vFade); # how long is one step (set hsv) in ms based on val
    $stepWide = $defaultDelay if ($stepWide < $defaultDelay);
    $steps = int($ramp * 1000 / $stepWide); # how many steps will we need ?
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} transit (V>H||S) steps: $steps stepwide: $stepWide");  
  }
        
  $hueToSet = $hueFrom; # prepare tmp working hue
  $hueStep = $rotation / $steps * $direction; # how big is one hue step base on timing choosen
          
  $satToSet = $satFrom; # prepare workin sat
  $satStep = ($sat - $satFrom) / $steps;
          
  $valToSet = $valFrom;
  $valStep = ($val - $valFrom) / $steps;

  #TODO do something more flexible
  #TODO remove if tested
  # $timeFrom += 1;

  for (my $i=1; $i <= $steps; $i++)
  {
    $hueToSet += $hueStep;
    $hueToSet -= 360 if ($hueToSet > 360); #handle turn over zero
    $hueToSet += 360 if ($hueToSet < 0);
    $satToSet += $satStep;
    $valToSet += $valStep;
    my $progress = 100 / $steps * $i;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} add to hl queue h:".($hueToSet).", s:".($satToSet).", v:".($valToSet)." ($i/$steps)");  
    WifiLight_HighLevelCmdQueue_Add($ledDevice, int($hueToSet +0.5), int($satToSet +0.5), int($valToSet +0.5), undef, $stepWide, int($progress +0.5), $event, $timeFrom + (($i-1) * $stepWide / 1000) );
  }
  $ledDevice->{helper}->{targetTime} = $timeFrom + $ramp;
  return undef;
}

sub
WifiLight_SetHSV_Target(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  $ledDevice->{helper}->{targetHue} = $hue;
  $ledDevice->{helper}->{targetSat} = $sat;
  $ledDevice->{helper}->{targetVal} = $val;
  return undef;
}

sub
WifiLight_setHSV_Readings(@)
{
  my ($ledDevice, $hue, $sat, $val) = @_;
  my ($r, $g, $b) = WifiLight_HSV2RGB($hue, $sat, $val);
  readingsBeginUpdate($ledDevice);
  readingsBulkUpdate($ledDevice, "hue", $hue % 360);
  readingsBulkUpdate($ledDevice, "saturation", $sat);
  readingsBulkUpdate($ledDevice, "brightness", $val);
  readingsBulkUpdate($ledDevice, "RGB", sprintf("%02X%02X%02X",$r,$g,$b));
  readingsBulkUpdate($ledDevice, "state", "on") if ($val > 0);
  readingsBulkUpdate($ledDevice, "state", "off") if ($val == 0);
  readingsEndUpdate($ledDevice, 1);
}

sub
WifiLight_HSV2RGB(@)
{
  my ($hue, $sat, $val) = @_;

  if ($sat == 0) 
  {
    return int(($val * 2.55) +0.5), int(($val * 2.55) +0.5), int(($val * 2.55) +0.5);
  }
  $hue %= 360;
  $hue /= 60;
  $sat /= 100;
  $val /= 100;

  my $i = int($hue);

  my $f = $hue - $i;
  my $p = $val * (1 - $sat);
  my $q = $val * (1 - $sat * $f);
  my $t = $val * (1 - $sat * (1 - $f));

  my ($r, $g, $b);

  if ( $i == 0 )
  {
    ($r, $g, $b) = ($val, $t, $p);
  }
  elsif ( $i == 1 )
  {
    ($r, $g, $b) = ($q, $val, $p);
  }
  elsif ( $i == 2 ) 
  {
    ($r, $g, $b) = ($p, $val, $t);
  }
  elsif ( $i == 3 ) 
  {
    ($r, $g, $b) = ($p, $q, $val);
  }
  elsif ( $i == 4 )
  {
    ($r, $g, $b) = ($t, $p, $val);
  }
  else
  {
    ($r, $g, $b) = ($val, $p, $q);
  }
  return (int(($r * 255) +0.5), int(($g * 255) +0.5), int(($b * 255) + 0.5));
}

sub
WifiLight_RGB2HSV(@)
{
  my ($ledDevice, $in) = @_;
  my $r = hex substr($in, 0, 2);
  my $g = hex substr($in, 2, 2);
  my $b = hex substr($in, 4, 2);
  my ($max, $min, $delta);
  my ($h, $s, $v);

  $max = $r if (($r >= $g) && ($r >= $b));
  $max = $g if (($g >= $r) && ($g >= $b));
  $max = $b if (($b >= $r) && ($b >= $g));
  $min = $r if (($r <= $g) && ($r <= $b));
  $min = $g if (($g <= $r) && ($g <= $b));
  $min = $b if (($b <= $r) && ($b <= $g));

  $v = int(($max / 2.55) + 0.5);  
  $delta = $max - $min;

  my $currentHue = ReadingsVal($ledDevice->{NAME}, "hue", 0);
  return ($currentHue, 0, $v) if (($max == 0) || ($delta == 0));

  $s = int((($delta / $max) *100) + 0.5);
  $h = ($g - $b) / $delta if ($r == $max);
  $h = 2 + ($b - $r) / $delta if ($g == $max);
  $h = 4 + ($r - $g) / $delta if ($b == $max);
  $h = int(($h * 60) + 0.5);
  $h += 360 if ($h < 0);
  return $h, $s, $v;
}

sub
WifiLight_HSV2fourChannel(@)
{
  my ($h, $s, $v) = @_;
  my ($r, $g, $b) = WifiLight_HSV2RGB($h, $s, $v);
  #white part, base 255
  my $white = 255;
  foreach ($r, $g, $b) { $white = $_ if ($_ < $white); }
  #remaining color part 
  my ($rr, $rg, $rb);
  $rr = $r - $white;
  $rg = $g - $white;
  $rb = $b - $white;
  return ($rr, $rg, $rb, $white);
}

sub
WifiLight_Milight_ColorConverter(@)
{
  my ($ledDevice) = @_;

  my @colorMap;
  
  my $hueRed = 0;
  my $adjRed = $hueRed;

  my $hueYellow = 60;
  my $adjYellow = $hueYellow;

  my $hueGreen = 120;
  my $adjGreen = $hueGreen;

  my $hueCyan = 180;
  my $adjCyan = $hueCyan;

  my $hueBlue = 240;
  my $adjBlue = $hueBlue;

  my $hueLilac = 300;
  my $adjLilac = $hueLilac;

  my $devRed = 176;
  #my $devYellow = 128;
  my $devYellow = 144;
  my $devGreen = 96;
  #my $devCyan = 48;
  my $devCyan = 56;
  my $devBlue = 16;
  my $devLilac = 224;

  my $i= 360;

  # red to yellow
  $adjRed += 360 if ($adjRed < 0); # in case of negative adjustment
  $devRed += 256 if ($devRed < $devYellow);
  $adjYellow += 360 if ($adjYellow < $adjRed);
  for ($i = $adjRed; $i <= $adjYellow; $i++)
  {
    $colorMap[$i % 360] = ($devRed - int((($devRed - $devYellow) / ($adjYellow - $adjRed)  * ($i - $adjRed)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #yellow to green
  $devYellow += 256 if ($devYellow < $devGreen);
  $adjGreen += 360 if ($adjGreen < $adjYellow);
  for ($i = $adjYellow; $i <= $adjGreen; $i++)
  {
    $colorMap[$i % 360] = ($devYellow - int((($devYellow - $devGreen) / ($adjGreen - $adjYellow)  * ($i - $adjYellow)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #green to cyan
  $devGreen += 256 if ($devGreen < $devCyan);
  $adjCyan += 360 if ($adjCyan < $adjGreen);
  for ($i = $adjGreen; $i <= $adjCyan; $i++)
  {
    $colorMap[$i % 360] = ($devGreen - int((($devGreen - $devCyan) / ($adjCyan - $adjGreen)  * ($i - $adjGreen)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #cyan to blue
  $devCyan += 256 if ($devCyan < $devCyan);
  $adjBlue += 360 if ($adjBlue < $adjCyan);
  for ($i = $adjCyan; $i <= $adjBlue; $i++)
  {
    $colorMap[$i % 360] = ($devCyan - int((($devCyan - $devBlue) / ($adjBlue - $adjCyan)  * ($i - $adjCyan)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #blue to lilac
  $devBlue += 256 if ($devBlue < $devLilac);
  $adjLilac += 360 if ($adjLilac < $adjBlue);
  for ($i = $adjBlue; $i <= $adjLilac; $i++)
  {
    $colorMap[$i % 360] = ($devBlue - int((($devBlue - $devLilac) / ($adjLilac - $adjBlue)  * ($i- $adjBlue)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  #lilac to red
  $devLilac += 256 if ($devLilac < $devRed);
  $adjRed += 360 if ($adjRed < $adjLilac);
  for ($i = $adjLilac; $i <= $adjRed; $i++)
  {
    $colorMap[$i % 360] = ($devLilac - int((($devLilac - $devRed) / ($adjRed - $adjLilac)  * ($i - $adjLilac)) +0.5)) % 255;
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} create colormap h: ".($i % 360)." d: ".$colorMap[$i % 360]); 
  }
  @{$ledDevice->{helper}->{COLORMAP}} = @colorMap;
  return \@colorMap;
}

sub
WifiLight_RGB_ColorConverter(@)
{
  # default correction +/- 29° 
  my ($ledDevice, $cr, $cy, $cg, $cc, $cb, $cm) = @_;
  #my ($cr, $cy, $cg, $cc, $cb, $cm) = (0, -30, -10, -30, 0, -10);

  my @colorMap;

  for (my $i = 0; $i <= 360; $i++)
  {
    my $toR = WifiLight_HueDistance(0, $i);
    my $toY = WifiLight_HueDistance(60, $i);
    my $toG = WifiLight_HueDistance(120, $i);
    my $toC = WifiLight_HueDistance(180, $i);
    my $toB = WifiLight_HueDistance(240, $i);
    my $toM = WifiLight_HueDistance(300, $i);
    
    my $c = 0; # $i;
    $c += $cr - ($cr * $toR / 60) if (abs($toR) <= 60);
    $c += $cy - ($cy * $toY / 60) if (abs($toY) <= 60);
    $c += $cg - ($cg * $toG / 60) if (abs($toG) <= 60);
    $c += $cc - ($cc * $toC / 60) if (abs($toC) <= 60);
    $c += $cb - ($cb * $toB / 60) if (abs($toB) <= 60);
    $c += $cm - ($cm * $toM / 60) if (abs($toM) <= 60);

    $colorMap[$i] = int($i + $c + 0.5) % 360;

    #$colorMap[$i] = (int($colorMap[$i] + ($cr - ($cr * $toR / 45)) + 0.5) + 360) % 360 if (abs($toR) <= 45);
    #$colorMap[$i] = (int($colorMap[$i] + ($cy - ($cy * $toY / 45)) + 0.5) + 360) % 360 if (abs($toY) <= 45);
    #$colorMap[$i] = (int($colorMap[$i] + ($cg - ($cg * $toG / 45)) + 0.5) + 360) % 360 if (abs($toG) <= 45);
  }
  @{$ledDevice->{helper}->{COLORMAP}} = @colorMap;
  return \@colorMap;
}

# calculate the distance of two given hue
sub
WifiLight_HueDistance(@)
{
  my ($hue, $testHue) = @_;
  my $a = (360 + $hue - $testHue) % 360;
  my $b = (360 + $testHue - $hue) % 360;
  return ($a, $b)[$a > $b];
}

# helper for easying access to attrib
sub
WifiLight_ccAttribVal(@)
{
  my ($ledDevice, $dr, $dy, $dg, $dc, $db, $dm) = @_;
  my $a = AttrVal($ledDevice->{NAME}, 'colorCast', undef);
  if ($a)
  {
    my ($cr, $cy, $cg, $cc, $cb, $cm) = split (',', $a);
  }
  else
  {
    my ($cr, $cy, $cg, $cc, $cb, $cm) = ($dr, $dy, $dg, $dc, $db, $dm);
  }
  return ($dr, $dy, $dg, $dc, $db, $dm);
}


sub
WifiLight_CreateGammaMapping(@)
{
  my ($ledDevice, $gamma) = @_;

  my @gammaMap;

  for (my $i = 0; $i <= 100; $i += 1)
  {
    my $correction = ($i / 100) ** (1 / $gamma); 
    $gammaMap[$i] = $correction * 100;
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} create gammamap v-in: ".$i.", v-out: $gammaMap[$i]");
  } 

  return \@gammaMap;
}

###############################################################################
#
# high level queue, long running color transitions
#
###############################################################################

sub
WifiLight_HighLevelCmdQueue_Add(@)
{
  my ($ledDevice, $hue, $sat, $val, $ctrl, $delay, $progress, $event, $targetTime) = @_;
  my $cmd;

  $cmd->{hue} = $hue;
  $cmd->{sat} = $sat;
  $cmd->{val} = $val;
  $cmd->{ctrl} = $ctrl;
  $cmd->{delay} = $delay;
  $cmd->{progress} = $progress;
  $cmd->{event} = $event;
  $cmd->{targetTime} = $targetTime;
  $cmd->{inProgess} = 0;

  push @{$ledDevice->{helper}->{hlCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{ctrl} || '');
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue add hsv/ctrl $cmd->{hue}, $cmd->{sat}, $cmd->{val}, ctrl $dbgStr, targetTime $cmd->{targetTime}, qlen ".@{$ledDevice->{helper}->{hlCmdQueue}});

  my $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];

  # sender busy ?
  return undef if (($actualCmd->{inProgess} || 0) == 1);
  return WifiLight_HighLevelCmdQueue_Exec($ledDevice);
}

sub
WifiLight_HighLevelCmdQueue_Exec(@)
{
  my ($ledDevice) = @_; 
  my $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];

  # transmission complete, remove
  shift @{$ledDevice->{helper}->{hlCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];
  my $nextCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[1];

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{inProgess}));

  # drop frames if next frame is already sceduled for given time. do not drop if it is the last frame or if it is a command  
  while (defined($nextCmd->{targetTime}) && ($nextCmd->{targetTime} < gettimeofday()) && !$actualCmd->{ctrl})
  {
    shift @{$ledDevice->{helper}->{hlCmdQueue}};
    $actualCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[0];
    $nextCmd = @{$ledDevice->{helper}->{hlCmdQueue}}[1];
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec drop frame at hlQueue level. hl qlen: ".@{$ledDevice->{helper}->{hlCmdQueue}});
  }
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} high level cmd queue exec dropper delay: ".($actualCmd->{targetTime} - gettimeofday()) );

  # set hsv or if a device ctrl command is sceduled: send it and ignore hsv
  if ($actualCmd->{ctrl})
  {
    my $dbgStr = unpack("H*", $actualCmd->{ctrl});
    Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec ctrl $dbgStr, qlen ".@{$ledDevice->{helper}->{hlCmdQueue}}); 
    WifiLight_sendCtrl($ledDevice, $actualCmd->{ctrl});
  }
  else
  {
    my $isLast = (@{$ledDevice->{helper}->{hlCmdQueue}} == 1)?1:undef;
    if (($ledDevice->{helper}->{llLock} == 0) || $isLast)
    {
      Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue exec hsv $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val}, delay $actualCmd->{delay}, hl qlen ".@{$ledDevice->{helper}->{hlCmdQueue}}.", ll qlen ".@{$ledDevice->{helper}->{llCmdQueue}}.", lock ".$ledDevice->{helper}->{llLock});
      WifiLight_setHSV($ledDevice, $actualCmd->{hue}, $actualCmd->{sat}, $actualCmd->{val}, $isLast);
    }
    else
    {
      Log3 ($ledDevice, 5, "$ledDevice->{NAME} high level cmd queue exec drop frame at llQueue level. ll qlen: ".@{$ledDevice->{helper}->{llCmdQueue}}.", lock ".$ledDevice->{helper}->{llLock});
    }
  }
  $actualCmd->{inProgess} = 1;
  my $next = defined($nextCmd->{targetTime})?$nextCmd->{targetTime}:gettimeofday() + ($actualCmd->{delay} / 1000);
  Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue ask next $next");
  InternalTimer($next, "WifiLight_HighLevelCmdQueue_Exec", $ledDevice, 0);
  WifiLight_processEvent($ledDevice, $actualCmd->{event}, $actualCmd->{progress});
  return undef;
}

sub
WifiLight_HighLevelCmdQueue_Clear(@)
{
  my ($ledDevice) = @_;
  foreach my $a (keys %intAt) 
  {
    if (($intAt{$a}{ARG} eq $ledDevice) && ($intAt{$a}{FN} eq 'WifiLight_HighLevelCmdQueue_Exec'))
    {

      Log3 ($ledDevice, 4, "$ledDevice->{NAME} high level cmd queue clear, remove timer at ".$intAt{$a}{TRIGGERTIME} );
      delete($intAt{$a}) ;
    }
  }
  $ledDevice->{helper}->{hlCmdQueue} = [];
}

# dispatcher for ctrl cmd
sub
WifiLight_sendCtrl(@)
{
  my ($ledDevice, $ctrl) = @_;
  # TODO adjust for all bridge types
  if  (($ledDevice->{LEDTYPE} eq 'RGB') && ($ledDevice->{CONNECTION} =~ 'bridge-V[2|3]'))
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'RGBW1')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'RGBW2')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 100;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
  if ($ledDevice->{LEDTYPE} eq 'White')
  {
    my $receiver = sockaddr_in($ledDevice->{PORT}, inet_aton($ledDevice->{IP}));
    my $delay = 10;
    WifiLight_LowLevelCmdQueue_Add($ledDevice, $ctrl, $receiver, $delay);
  }
}

###############################################################################
#
# atomic low level udp communication to device
# required because there are timing requirements, mostly limitaions in processing speed of the bridge
# the commands should never be interrupted or canceled because some fhem readings are set in advance
#
###############################################################################

sub
WifiLight_LowLevelCmdQueue_Add(@)
{
  my ($ledDevice, $command, $receiver, $delay, $unlock) = @_;
  my $cmd;

  $cmd->{command} = $command;
  $cmd->{sender} = $ledDevice;
  $cmd->{receiver} = $receiver;
  $cmd->{delay} = $delay;
  $cmd->{unlock} = $unlock;
  $cmd->{inProgess} = 0;

  # push cmd into queue
  push @{$ledDevice->{helper}->{llCmdQueue}}, $cmd;

  my $dbgStr = unpack("H*", $cmd->{command});
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} low level cmd queue add $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}); 

  my $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
 
  # sender busy ?
  return undef if ($actualCmd->{inProgess});
  return WifiLight_LowLevelCmdQueue_Send($ledDevice);
}

sub
WifiLight_LowLevelCmdQueue_Send(@)
{
  my ($ledDevice) = @_; 
  my $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];

  # transmission complete, remove
  shift @{$ledDevice->{helper}->{llCmdQueue}} if ($actualCmd->{inProgess});

  # next in queue
  $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
  
  # remove a low level queue lock if present and get next 
  while (($actualCmd->{unlock} || 0) == 1) 
  { 
    $actualCmd->{sender}->{helper}->{llLock} -= 1;
    Log3 ($ledDevice, 5, "$ledDevice->{NAME} | $actualCmd->{sender}->{NAME} unlock queue ".$actualCmd->{sender}->{helper}->{llLock});
    shift @{$ledDevice->{helper}->{llCmdQueue}}; 
    $actualCmd = @{$ledDevice->{helper}->{llCmdQueue}}[0];
  }

  # return if no more elements in queue
  return undef if (!defined($actualCmd->{command}));

  my $dbgStr = unpack("H*", $actualCmd->{command});
  Log3 ($ledDevice, 5, "$ledDevice->{NAME} low level cmd queue qlen ".@{$ledDevice->{helper}->{llCmdQueue}}.", send $dbgStr");

  # TCP LW12
  if ($ledDevice->{PROTO})
  {
    if (!$ledDevice->{helper}->{SOCKET} || ($ledDevice->{helper}->{SELECT}->can_read(0.0001) && !$ledDevice->{helper}->{SOCKET}->recv(my $data, 512)))
    {
      Log3 ($ledDevice, 4, "$ledDevice->{NAME} low level cmd queue send $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}." connection refused: trying to reconnect");

      $ledDevice->{helper}->{SOCKET}->close() if $ledDevice->{helper}->{SOCKET};

      $ledDevice->{helper}->{SOCKET} = IO::Socket::INET-> new (
        PeerPort => $ledDevice->{PORT},
        PeerAddr => $ledDevice->{IP},
        Timeout => 1,
        Blocking => 0,
        Proto => 'tcp') or Log3 ($ledDevice, 3, "$ledDevice->{NAME} low level cmd queue send ERROR $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}}." (reconnect giving up)");
      $ledDevice->{helper}->{SELECT} = IO::Select->new($ledDevice->{helper}->{SOCKET}) if $ledDevice->{helper}->{SOCKET};
    }
    $ledDevice->{helper}->{SOCKET}->send($actualCmd->{command}) if $ledDevice->{helper}->{SOCKET};
  }
  else
  {
    # print "send: $ledDevice->{NAME} $dbgStr \n";
    send($ledDevice->{helper}->{SOCKET}, $actualCmd->{command}, 0, $actualCmd->{receiver}) or Log3 ($ledDevice, 1, "$ledDevice->{NAME} low level cmd queue send ERROR $@ $dbgStr, qlen ".@{$ledDevice->{helper}->{llCmdQueue}});
  }

  $actualCmd->{inProgess} = 1;
  my $msec = $actualCmd->{delay} / 1000;
  InternalTimer(gettimeofday()+$msec, "WifiLight_LowLevelCmdQueue_Send", $ledDevice, 0);
  return undef;
}

1;

=begin html
<a name="Wifilight"></a>
This module is the interface to several WiFi Controller which are connected to the network using a Wifi connection. It could be used for the following devices:
 <ul>
  <li>Mi-Light</li>
  <li>Limitless</li>
  <li>IVY</li>
  <li>LW12</li>
  <li>LD382</li>
  <li>LED stripes</li>
  <li>E27 RGB bulbs</li>
</ul>
=end html

=begin html_DE
<a name="Wifilight"></a>
Diese Modul kann dazu verwendet werden um Wifi-LED Controller zu steuern die mit dem Netzwerk ueber das WLAN verbunden sind. Die folgenden Geraete werden zur Zeit unterstuetzt:
 <ul>
  <li>Mi-Light</li>
  <li>Limitless</li>
  <li>IVY</li>
  <li>LW12</li>
  <li>LD382</li>
  <li>LED stripes</li>
  <li>E27 RGB bulbs</li>
</ul>
=end html_DE
