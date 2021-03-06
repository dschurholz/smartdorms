# $Id: 20_GUEST.pm 13439 2017-02-18 21:10:08Z loredo $
##############################################################################
#
#     20_GUEST.pm
#     Submodule of 10_RESIDENTS.
#
#     Copyright by Julian Pawlowski
#     e-mail: julian.pawlowski at gmail.com
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################

package main;

use strict;
use warnings;
use Time::Local;
use Data::Dumper;
require RESIDENTStk;

no if $] >= 5.017011, warnings => 'experimental';

sub GUEST_Set($@);
sub GUEST_Define($$);
sub GUEST_Notify($$);
sub GUEST_Undefine($$);

###################################
sub GUEST_Initialize($) {
    my ($hash) = @_;

    Log3 $hash, 5, "GUEST_Initialize: Entering";

    $hash->{SetFn}    = "GUEST_Set";
    $hash->{DefFn}    = "GUEST_Define";
    $hash->{NotifyFn} = "GUEST_Notify";
    $hash->{UndefFn}  = "GUEST_Undefine";
    $hash->{AttrList} =
"rg_locationHome rg_locationWayhome rg_locationUnderway rg_autoGoneAfter:12,16,24,26,28,30,36,48,60 rg_showAllStates:0,1 rg_realname:group,alias rg_states:multiple-strict,home,gotosleep,asleep,awoken,absent,gone rg_locations rg_moods rg_moodDefault rg_moodSleepy rg_noDuration:0,1 rg_wakeupDevice rg_geofenceUUIDs rg_presenceDevices "
      . $readingFnAttributes;
}

###################################
sub GUEST_Define($$) {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    my $name = $hash->{NAME};
    my $name_attr;

    Log3 $name, 5, "GUEST $name: called function GUEST_Define()";

    if ( int(@a) < 2 ) {
        my $msg = "Wrong syntax: define <name> GUEST [RESIDENTS-DEVICE-NAMES]";
        Log3 $name, 4, $msg;
        return $msg;
    }

    $hash->{TYPE} = "GUEST";

    my $parents = ( defined( $a[2] ) ? $a[2] : "" );

    # unregister at parent objects if we get modified
    my @registeredResidentgroups;
    my $modified = 0;
    if ( defined( $hash->{RESIDENTGROUPS} ) && $hash->{RESIDENTGROUPS} ne "" ) {
        $modified = 1;
        @registeredResidentgroups =
          split( /,/, $hash->{RESIDENTGROUPS} );

        # unregister at parent objects
        foreach my $parent (@registeredResidentgroups) {
            if ( defined( $defs{$parent} )
                && $defs{$parent}{TYPE} eq "RESIDENTS" )
            {
                fhem("set $parent unregister $name");
                Log3 $name, 4,
                  "GUEST $name: Unregistered at RESIDENTS device $parent";
            }
        }
    }

    # register at parent objects
    $hash->{RESIDENTGROUPS} = "";
    if ( $parents ne "" ) {
        @registeredResidentgroups = split( /,/, $parents );
        foreach my $parent (@registeredResidentgroups) {
            if ( !defined( $defs{$parent} ) ) {
                Log3 $name, 3,
"GUEST $name: Unable to register at RESIDENTS device $parent (not existing)";
                next;
            }

            if ( $defs{$parent}{TYPE} ne "RESIDENTS" ) {
                Log3 $name, 3,
"GUEST $name: Device $parent is not a RESIDENTS device (wrong type)";
                next;
            }

            fhem("set $parent register $name");
            $hash->{RESIDENTGROUPS} .= $parent . ",";
            Log3 $name, 4,
              "GUEST $name: Registered at RESIDENTS device $parent";
        }
    }
    else {
        $modified = 0;
    }

    # set reverse pointer
    $modules{GUEST}{defptr}{$name} = \$hash;

    readingsBeginUpdate($hash);

    # set default settings on first define
    if ( $init_done && !defined( $hash->{OLDDEF} ) ) {
        my $aliasname = $name;
        $aliasname =~ s/^rg_//;
        $attr{$name}{alias} = $aliasname;

        $attr{$name}{devStateIcon} =
".*home:user_available:absent .*absent:user_away:home .*none:control_building_empty:home .*gotosleep:scene_toilet:asleep .*asleep:scene_sleeping:awoken .*awoken:scene_sleeping_alternat:home .*:user_unknown:home";
        $attr{$name}{group}       = "Guests";
        $attr{$name}{icon}        = "scene_visit_guests";
        $attr{$name}{rg_realname} = "alias";
        $attr{$name}{sortby}      = "1";
        $attr{$name}{webCmd}      = "state";

        $attr{$name}{room} = $attr{ $registeredResidentgroups[0] }{room}
          if ( @registeredResidentgroups
            && exists( $attr{ $registeredResidentgroups[0] }{room} ) );
    }

    # trigger for modified objects
    unless ( $modified == 0 ) {
        readingsBulkUpdate( $hash, "state", ReadingsVal( $name, "state", "" ) );
    }

    readingsEndUpdate( $hash, 1 );

    # run timers
    InternalTimer( gettimeofday() + 15, "GUEST_StartInternalTimers", $hash, 0 );

    # Injecting AttrFn for use with RESIDENTS Toolkit
    if ( !defined( $modules{dummy}{AttrFn} ) ) {
        $modules{dummy}{AttrFn} = "RESIDENTStk_AttrFnDummy";
    }
    elsif ( $modules{dummy}{AttrFn} ne "RESIDENTStk_AttrFnDummy" ) {
        Log3 $name, 4,
"RESIDENTStk $name: concurrent AttrFn already defined for dummy module ("
          . $modules{dummy}{AttrFn}
          . "). Some attribute based functions like auto-creations will not be available.";
    }

    return undef;
}

###################################
sub GUEST_Undefine($$) {
    my ( $hash, $name ) = @_;

    RESIDENTStk_RemoveInternalTimer( "AutoGone",      $hash );
    RESIDENTStk_RemoveInternalTimer( "DurationTimer", $hash );

    if ( defined( $hash->{RESIDENTGROUPS} ) ) {
        my @registeredResidentgroups =
          split( /,/, $hash->{RESIDENTGROUPS} );

        # unregister at parent objects
        foreach my $parent (@registeredResidentgroups) {
            if ( defined( $defs{$parent} )
                && $defs{$parent}{TYPE} eq "RESIDENTS" )
            {
                fhem("set $parent unregister $name");
                Log3 $name, 4,
                  "GUEST $name: Unregistered at RESIDENTS device $parent";
            }
        }
    }

    # release reverse pointer
    delete $modules{GUEST}{defptr}{$name};

    return undef;
}

###################################
sub GUEST_Notify($$) {
    my ( $hash, $dev ) = @_;
    my $devName  = $dev->{NAME};
    my $hashName = $hash->{NAME};

    # process global:INITIALIZED
    if ( $dev->{NAME} eq "global"
        && grep( m/^INITIALIZED$/, @{ $dev->{CHANGED} } ) )
    {

        my @registeredWakeupdevs =
          split( /,/, AttrVal( $hashName, "rg_wakeupDevice", 0 ) );

        # if we have registered wakeup devices
        if (@registeredWakeupdevs) {

            # look for at devices for each wakeup device
            foreach my $wakeupDev (@registeredWakeupdevs) {
                my $wakeupAtdevice = AttrVal( $wakeupDev, "wakeupAtdevice", 0 );

                # make sure computeAfterInit is set at at-device
                # and re-calculate on our own this time
                if (   defined( $defs{$wakeupAtdevice} )
                    && $defs{$wakeupAtdevice}{TYPE} eq "at"
                    && AttrVal( $wakeupAtdevice, "computeAfterInit", 0 ) ne
                    "1" )
                {
                    Log3 $wakeupDev, 3,
"RESIDENTStk $wakeupDev: Correcting '$wakeupAtdevice' attribute computeAfterInit required for correct recalculation after reboot";
                    fhem "attr $wakeupAtdevice computeAfterInit 1";

                    my $command;
                    ( $command, undef ) =
                      split( "[ \t]+", $defs{$wakeupAtdevice}{DEF}, 2 );
                    $command =~ s/^[*+]//;
                    return at_Set( $defs{$wakeupAtdevice},
                        ( $wakeupAtdevice, "modifyTimeSpec", $command ) );
                }
            }
        }
    }

    # process child notifies
    elsif ( $devName ne $hashName ) {
        my @registeredWakeupdevs =
          split( ',', AttrVal( $hashName, "rg_wakeupDevice", "" ) );
        my @presenceDevices =
          split( ',', AttrVal( $hashName, "rg_presenceDevices", "" ) );

        # if we have registered wakeup devices
        if (@registeredWakeupdevs) {

            # if this is a notification of a registered wakeup device
            if ( $devName ~~ @registeredWakeupdevs ) {

                # Some previous notify deleted the array.
                return
                  if ( !$dev->{CHANGED} );

                foreach my $change ( @{ $dev->{CHANGED} } ) {
                    RESIDENTStk_wakeupSet( $devName, $change );
                }

                return;
            }

            # process sub-child notifies: *_wakeupDevice
            foreach my $wakeupDev (@registeredWakeupdevs) {

                # if this is a notification of a registered sub dummy device
                # of one of our wakeup devices
                if (
                    AttrVal( $wakeupDev, "wakeupResetSwitcher", "" ) eq $devName
                    && $dev->{TYPE} eq "dummy" )
                {

                    # Some previous notify deleted the array.
                    return
                      if ( !$dev->{CHANGED} );

                    foreach my $change ( @{ $dev->{CHANGED} } ) {
                        RESIDENTStk_wakeupSet( $wakeupDev, $change )
                          if ( $change ne "off" );
                    }

                    last;
                }
            }
        }

        # process PRESENCE
        if ( @presenceDevices && $devName ~~ @presenceDevices ) {

            my $counter = {
                absent  => 0,
                present => 0,
            };

            foreach (@presenceDevices) {
                my $presenceState =
                  ReadingsVal( $_, "presence", ReadingsVal( $_, "state", "" ) );
                next
                  unless ( $presenceState =~
/^((absent|disappeared|unavailable)|(present|appeared|available|))$/i
                  );

                $counter->{absent}++  if ($2);
                $counter->{present}++ if ($3);
            }

            if ( $counter->{absent} && !$counter->{present} ) {
                Log3 $hashName, 4,
                  "GUEST $hashName: Syncing status with $devName = absent";
                fhem "set $hashName:FILTER=presence=present absent";
            }
            elsif ( $counter->{present} ) {
                Log3 $hashName, 4,
                  "GUEST $hashName: Syncing status with $devName = present";
                fhem "set $hashName:FILTER=presence=absent home";
            }
        }
    }

    return;
}

###################################
sub GUEST_Set($@) {
    my ( $hash, @a ) = @_;
    my $name     = $hash->{NAME};
    my $state    = ReadingsVal( $name, "state", "initialized" );
    my $presence = ReadingsVal( $name, "presence", "undefined" );
    my $mood     = ReadingsVal( $name, "mood", "-" );
    my $location = ReadingsVal( $name, "location", "undefined" );
    my $silent   = 0;

    Log3 $name, 5, "GUEST $name: called function GUEST_Set()";

    return "No Argument given" if ( !defined( $a[1] ) );

    # depending on current FHEMWEB instance's allowedCommands,
    # restrict set commands if there is "set-user" in it
    my $adminMode         = 1;
    my $FWallowedCommands = 0;
    $FWallowedCommands = AttrVal( $FW_wname, "allowedCommands", 0 )
      if ( defined($FW_wname) );
    if ( $FWallowedCommands && $FWallowedCommands =~ m/\bset-user\b/ ) {
        $adminMode = 0;
        return "Forbidden command: set " . $a[1]
          if ( lc( $a[1] ) eq "create" );
    }

    # states
    my $states = (
        defined( $attr{$name}{rg_states} ) ? $attr{$name}{rg_states}
        : (
            defined( $attr{$name}{rg_showAllStates} )
              && $attr{$name}{rg_showAllStates} == 1
            ? "home,gotosleep,asleep,awoken,absent,none"
            : "home,gotosleep,absent,none"
        )
    );
    $states = $state . "," . $states if ( $states !~ /$state/ );
    $states =~ s/ /,/g;

    # moods
    my $moods = (
        defined( $attr{$name}{rg_moods} )
        ? $attr{$name}{rg_moods} . ",toggle"
        : "calm,relaxed,happy,excited,lonely,sad,bored,stressed,uncomfortable,sleepy,angry,toggle"
    );
    $moods = $mood . "," . $moods if ( $moods !~ /$mood/ );
    $moods =~ s/ /,/g;

    # locations
    my $locations = (
        defined( $attr{$name}{rg_locations} )
        ? $attr{$name}{rg_locations}
        : ""
    );
    if (   $locations !~ /$location/
        && $locations ne "" )
    {
        $locations = ":" . $location . "," . $locations;
    }
    elsif ( $locations ne "" ) {
        $locations = ":" . $locations;
    }
    $locations =~ s/ /,/g;

    my $usage = "Unknown argument " . $a[1] . ", choose one of state:$states";
    $usage .= " mood:$moods";
    $usage .= " location$locations";
    if ($adminMode) {
        $usage .= " create:wakeuptimer";
        $usage .= ",locationMap"
          if ( ReadingsVal( $name, "locationLat", "-" ) ne "-"
            && ReadingsVal( $name, "locationLong", "-" ) ne "-" );
    }

    # silentSet
    if ( $a[1] eq "silentSet" ) {
        $silent = 1;
        my $first = shift @a;
        $a[0] = $first;
    }

    # states
    if (   $a[1] eq "state"
        || $a[1] eq "home"
        || $a[1] eq "gotosleep"
        || $a[1] eq "asleep"
        || $a[1] eq "awoken"
        || $a[1] eq "absent"
        || $a[1] eq "none"
        || $a[1] eq "gone" )
    {
        my $newstate;

        # if not direct
        if (
               $a[1] eq "state"
            && defined( $a[2] )
            && (   $a[2] eq "home"
                || $a[2] eq "gotosleep"
                || $a[2] eq "asleep"
                || $a[2] eq "awoken"
                || $a[2] eq "absent"
                || $a[2] eq "none"
                || $a[2] eq "gone" )
          )
        {
            $newstate = $a[2];
        }
        elsif ( defined( $a[2] ) ) {
            return
"Invalid 2nd argument, choose one of home gotosleep asleep awoken absent none ";
        }
        else {
            $newstate = $a[1];
        }

        $newstate = "none" if ( $newstate eq "gone" );

        Log3 $name, 2, "GUEST set $name " . $newstate if ( !$silent );

        # if state changed
        if ( $state ne $newstate ) {
            readingsBeginUpdate($hash);

            readingsBulkUpdate( $hash, "lastState", $state );
            readingsBulkUpdate( $hash, "state",     $newstate );

            my $datetime = TimeNow();

            # reset mood
            my $mood_default =
              ( defined( $attr{$name}{"rg_moodDefault"} ) )
              ? $attr{$name}{"rg_moodDefault"}
              : "calm";
            my $mood_sleepy =
              ( defined( $attr{$name}{"rg_moodSleepy"} ) )
              ? $attr{$name}{"rg_moodSleepy"}
              : "sleepy";

            if (
                $mood ne "-"
                && (   $newstate eq "gone"
                    || $newstate eq "none"
                    || $newstate eq "absent"
                    || $newstate eq "asleep" )
              )
            {
                Log3 $name, 4,
                  "GUEST $name: implicit mood change caused by state "
                  . $newstate;
                GUEST_Set( $hash, $name, "silentSet", "mood", "-" );
            }

            elsif ( $mood ne $mood_sleepy
                && ( $newstate eq "gotosleep" || $newstate eq "awoken" ) )
            {
                Log3 $name, 4,
                  "GUEST $name: implicit mood change caused by state "
                  . $newstate;
                GUEST_Set( $hash, $name, "silentSet", "mood", $mood_sleepy );
            }

            elsif ( ( $mood eq "-" || $mood eq $mood_sleepy )
                && $newstate eq "home" )
            {
                Log3 $name, 4,
                  "GUEST $name: implicit mood change caused by state "
                  . $newstate;
                GUEST_Set( $hash, $name, "silentSet", "mood", $mood_default );
            }

            # if state is asleep, start sleep timer
            readingsBulkUpdate( $hash, "lastSleep", $datetime )
              if ( $newstate eq "asleep" );

            # if prior state was asleep, update sleep statistics
            if ( $state eq "asleep"
                && ReadingsVal( $name, "lastSleep", "" ) ne "" )
            {
                readingsBulkUpdate( $hash, "lastAwake", $datetime );
                readingsBulkUpdate(
                    $hash,
                    "lastDurSleep",
                    RESIDENTStk_TimeDiff(
                        $datetime, ReadingsVal( $name, "lastSleep", "" )
                    )
                );
                readingsBulkUpdate(
                    $hash,
                    "lastDurSleep_cr",
                    RESIDENTStk_TimeDiff(
                        $datetime, ReadingsVal( $name, "lastSleep", "" ),
                        "min"
                    )
                );
            }

            # calculate presence state
            my $newpresence =
              (      $newstate ne "none"
                  && $newstate ne "gone"
                  && $newstate ne "absent" )
              ? "present"
              : "absent";

            # stop any running wakeup-timers in case state changed
            my $wakeupState = ReadingsVal( $name, "wakeup", 0 );
            if ( $wakeupState > 0 ) {
                my $wakeupDeviceList = AttrVal( $name, "rg_wakeupDevice", 0 );

                for my $wakeupDevice ( split /,/, $wakeupDeviceList ) {
                    next if !$wakeupDevice;

                    if ( defined( $defs{$wakeupDevice} )
                        && $defs{$wakeupDevice}{TYPE} eq "dummy" )
                    {
                        # forced-stop only if resident is not present anymore
                        if ( $newpresence eq "present" ) {
                            Log3 $name, 4,
"ROOMMATE $name: ending wakeup-timer $wakeupDevice";
                            fhem "set $wakeupDevice:FILTER=running!=0 end";
                        }
                        else {
                            Log3 $name, 4,
"ROOMMATE $name: stopping wakeup-timer $wakeupDevice";
                            fhem "set $wakeupDevice:FILTER=running!=0 stop";
                        }
                    }
                }
            }

            # if presence changed
            if ( $newpresence ne $presence ) {
                readingsBulkUpdate( $hash, "presence", $newpresence );

                # update location
                my @location_home =
                  split( ' ', AttrVal( $name, "rg_locationHome", "home" ) );
                my @location_underway =
                  split( ' ',
                    AttrVal( $name, "rg_locationUnderway", "underway" ) );
                my @location_wayhome =
                  split( ' ',
                    AttrVal( $name, "rg_locationWayhome", "wayhome" ) );
                my $searchstring = quotemeta($location);

                if ( $newpresence eq "present" ) {
                    if ( !grep( m/^$searchstring$/, @location_home )
                        && $location ne $location_home[0] )
                    {
                        Log3 $name, 4,
"GUEST $name: implicit location change caused by state "
                          . $newstate;
                        GUEST_Set( $hash, $name, "silentSet", "location",
                            $location_home[0] );
                    }
                }
                else {
                    if (   !$silent
                        && !grep( m/^$searchstring$/, @location_underway )
                        && $location ne $location_underway[0] )
                    {
                        Log3 $name, 4,
"GUEST $name: implicit location change caused by state "
                          . $newstate;
                        GUEST_Set( $hash, $name, "silentSet", "location",
                            $location_underway[0] );
                    }
                }

                # reset wayhome
                if ( ReadingsVal( $name, "wayhome", 1 ) > 0 ) {
                    readingsBulkUpdate( $hash, "wayhome", "0" );
                }

                # update statistics
                if ( $newpresence eq "present" ) {
                    readingsBulkUpdate( $hash, "lastArrival", $datetime );

                    # absence duration
                    if ( ReadingsVal( $name, "lastDeparture", "-" ) ne "-" ) {
                        readingsBulkUpdate(
                            $hash,
                            "lastDurAbsence",
                            RESIDENTStk_TimeDiff(
                                $datetime,
                                ReadingsVal( $name, "lastDeparture", "-" )
                            )
                        );
                        readingsBulkUpdate(
                            $hash,
                            "lastDurAbsence_cr",
                            RESIDENTStk_TimeDiff(
                                $datetime,
                                ReadingsVal( $name, "lastDeparture", "-" ),
                                "min"
                            )
                        );
                    }
                }
                else {
                    readingsBulkUpdate( $hash, "lastDeparture", $datetime );

                    # presence duration
                    if ( ReadingsVal( $name, "lastArrival", "-" ) ne "-" ) {
                        readingsBulkUpdate(
                            $hash,
                            "lastDurPresence",
                            RESIDENTStk_TimeDiff(
                                $datetime,
                                ReadingsVal( $name, "lastArrival", "-" )
                            )
                        );
                        readingsBulkUpdate(
                            $hash,
                            "lastDurPresence_cr",
                            RESIDENTStk_TimeDiff(
                                $datetime,
                                ReadingsVal( $name, "lastArrival", "-" ), "min"
                            )
                        );
                    }
                }

                # adjust linked objects
                if ( defined( $attr{$name}{"rg_passPresenceTo"} )
                    && $attr{$name}{"rg_passPresenceTo"} ne "" )
                {
                    my @linkedObjects =
                      split( ' ', $attr{$name}{"rg_passPresenceTo"} );

                    foreach my $object (@linkedObjects) {
                        if (
                               defined( $defs{$object} )
                            && $defs{$object} ne $name
                            && defined( $defs{$object}{TYPE} )
                            && (   $defs{$object}{TYPE} eq "ROOMMATE"
                                || $defs{$object}{TYPE} eq "GUEST" )
                            && ReadingsVal( $object, "state", "" ) ne "gone"
                            && ReadingsVal( $object, "state", "" ) ne "none"
                          )
                        {
                            fhem("set $object $newstate");
                        }
                    }
                }
            }

            # clear readings if guest is gone
            if ( $newstate eq "none" ) {
                readingsBulkUpdate( $hash, "lastArrival", "-" )
                  if ( ReadingsVal( $name, "lastArrival", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastAwake", "-" )
                  if ( ReadingsVal( $name, "lastAwake", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastDurAbsence", "-" )
                  if ( ReadingsVal( $name, "lastDurAbsence", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastDurSleep", "-" )
                  if ( ReadingsVal( $name, "lastDurSleep", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastLocation", "-" )
                  if ( ReadingsVal( $name, "lastLocation", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastSleep", "-" )
                  if ( ReadingsVal( $name, "lastSleep", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "lastMood", "-" )
                  if ( ReadingsVal( $name, "lastMood", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "location", "-" )
                  if ( ReadingsVal( $name, "location", "-" ) ne "-" );
                readingsBulkUpdate( $hash, "mood", "-" )
                  if ( ReadingsVal( $name, "mood", "-" ) ne "-" );
            }

            # calculate duration timers
            GUEST_DurationTimer( $hash, $silent );

            readingsEndUpdate( $hash, 1 );

            # enable or disable AutoGone timer
            if ( $newstate eq "absent" ) {
                GUEST_AutoGone($hash);
            }
            elsif ( $state eq "absent" ) {
                RESIDENTStk_RemoveInternalTimer( "AutoGone", $hash );
            }
        }
    }

    # mood
    elsif ( $a[1] eq "mood" ) {
        if ( defined( $a[2] ) && $a[2] ne "" ) {
            Log3 $name, 2, "GUEST set $name mood " . $a[2] if ( !$silent );
            readingsBeginUpdate($hash) if ( !$silent );

            if ( $a[2] eq "toggle"
                && ReadingsVal( $name, "lastMood", "" ) ne "" )
            {
                readingsBulkUpdate( $hash, "mood",
                    ReadingsVal( $name, "lastMood", "" ) );
                readingsBulkUpdate( $hash, "lastMood", $mood );
            }
            elsif ( $mood ne $a[2] ) {
                readingsBulkUpdate( $hash, "lastMood", $mood )
                  if ( $mood ne "-" );
                readingsBulkUpdate( $hash, "mood", $a[2] );
            }

            readingsEndUpdate( $hash, 1 ) if ( !$silent );
        }
        else {
            return "Invalid 2nd argument, choose one of mood toggle";
        }
    }

    # location
    elsif ( $a[1] eq "location" ) {
        if ( defined( $a[2] ) && $a[2] ne "" ) {
            Log3 $name, 2, "GUEST set $name location " . $a[2] if ( !$silent );

            if ( $location ne $a[2] ) {
                my $searchstring;

                readingsBeginUpdate($hash) if ( !$silent );

                # read attributes
                my @location_home =
                  split( ' ', AttrVal( $name, "rg_locationHome", "home" ) );
                my @location_underway =
                  split( ' ',
                    AttrVal( $name, "rg_locationUnderway", "underway" ) );
                my @location_wayhome =
                  split( ' ',
                    AttrVal( $name, "rg_locationWayhome", "wayhome" ) );

                $searchstring = quotemeta($location);
                readingsBulkUpdate( $hash, "lastLocation", $location )
                  if ( $location ne "wayhome"
                    && !grep( m/^$searchstring$/, @location_underway ) );
                readingsBulkUpdate( $hash, "location", $a[2] )
                  if ( $a[2] ne "wayhome" );

                # wayhome detection
                $searchstring = quotemeta($location);
                if (
                    (
                        $a[2] eq "wayhome"
                        || grep( m/^$searchstring$/, @location_wayhome )
                    )
                    && ( $presence eq "absent" )
                  )
                {
                    Log3 $name, 3,
                      "GUEST $name: on way back home from $location";
                    readingsBulkUpdate( $hash, "wayhome", "1" )
                      if ( ReadingsVal( $name, "wayhome", "0" ) ne "1" );
                }

                readingsEndUpdate( $hash, 1 ) if ( !$silent );

                # auto-updates
                $searchstring = quotemeta( $a[2] );
                if (
                    (
                        $a[2] eq "home"
                        || grep( m/^$searchstring$/, @location_home )
                    )
                    && $state ne "home"
                    && $state ne "gotosleep"
                    && $state ne "asleep"
                    && $state ne "awoken"
                    && $state ne "initialized"
                  )
                {
                    Log3 $name, 4,
                      "GUEST $name: implicit state change caused by location "
                      . $a[2];
                    GUEST_Set( $hash, $name, "silentSet", "state", "home" );
                }
                elsif (
                    (
                        $a[2] eq "underway"
                        || grep( m/^$searchstring$/, @location_underway )
                    )
                    && $state ne "gone"
                    && $state ne "none"
                    && $state ne "absent"
                    && $state ne "initialized"
                  )
                {
                    Log3 $name, 4,
                      "GUEST $name: implicit state change caused by location "
                      . $a[2];
                    GUEST_Set( $hash, $name, "silentSet", "state", "absent" );
                }
            }
        }
        else {
            return "Invalid 2nd argument, choose one of location ";
        }
    }

    # create
    elsif ( lc( $a[1] ) eq "create" ) {
        if ( !defined( $a[2] ) ) {
            return
              "Invalid 2nd argument, choose one of wakeuptimer locationMap ";
        }
        elsif ( lc( $a[2] ) eq "wakeuptimer" ) {
            my $i               = "1";
            my $wakeuptimerName = $name . "_wakeuptimer" . $i;
            my $created         = 0;

            until ($created) {
                if ( defined( $defs{$wakeuptimerName} ) ) {
                    $i++;
                    $wakeuptimerName = $name . "_wakeuptimer" . $i;
                }
                else {
                    my $sortby = AttrVal( $name, "sortby", -1 );
                    $sortby++;

                    # create new dummy device
                    fhem "define $wakeuptimerName dummy";
                    fhem "attr $wakeuptimerName alias Wake-up Timer $i";
                    fhem
"attr $wakeuptimerName comment Auto-created by GUEST module for use with RESIDENTS Toolkit";
                    fhem
"attr $wakeuptimerName devStateIcon OFF:general_aus\@red:reset running:general_an\@green:stop .*:general_an\@orange:nextRun%20OFF";
                    fhem "attr $wakeuptimerName group " . $attr{$name}{group}
                      if ( defined( $attr{$name}{group} ) );
                    fhem "attr $wakeuptimerName icon time_timer";
                    fhem "attr $wakeuptimerName room " . $attr{$name}{room}
                      if ( defined( $attr{$name}{room} ) );
                    fhem
"attr $wakeuptimerName setList nextRun:OFF,00:00,00:15,00:30,00:45,01:00,01:15,01:30,01:45,02:00,02:15,02:30,02:45,03:00,03:15,03:30,03:45,04:00,04:15,04:30,04:45,05:00,05:15,05:30,05:45,06:00,06:15,06:30,06:45,07:00,07:15,07:30,07:45,08:00,08:15,08:30,08:45,09:00,09:15,09:30,09:45,10:00,10:15,10:30,10:45,11:00,11:15,11:30,11:45,12:00,12:15,12:30,12:45,13:00,13:15,13:30,13:45,14:00,14:15,14:30,14:45,15:00,15:15,15:30,15:45,16:00,16:15,16:30,16:45,17:00,17:15,17:30,17:45,18:00,18:15,18:30,18:45,19:00,19:15,19:30,19:45,20:00,20:15,20:30,20:45,21:00,21:15,21:30,21:45,22:00,22:15,22:30,22:45,23:00,23:15,23:30,23:45 reset:noArg trigger:noArg start:noArg stop:noArg end:noArg";
                    fhem "attr $wakeuptimerName userattr wakeupUserdevice";
                    fhem "attr $wakeuptimerName sortby " . $sortby
                      if ($sortby);
                    fhem "attr $wakeuptimerName wakeupUserdevice $name";
                    fhem "attr $wakeuptimerName webCmd nextRun";

                    # register slave device
                    my $wakeupDevice = AttrVal( $name, "rg_wakeupDevice", 0 );
                    if ( !$wakeupDevice ) {
                        fhem "attr $name rg_wakeupDevice $wakeuptimerName";
                    }
                    elsif ( $wakeupDevice !~ /(.*,?)($wakeuptimerName)(.*,?)/ )
                    {
                        fhem "attr $name rg_wakeupDevice "
                          . $wakeupDevice
                          . ",$wakeuptimerName";
                    }

                    # trigger first update
                    fhem "set $wakeuptimerName nextRun OFF";

                    $created = 1;
                }
            }

            return
"Dummy $wakeuptimerName and other pending devices created and pre-configured.\nYou may edit Macro_$wakeuptimerName to define your wake-up actions\nand at_$wakeuptimerName for optional at-device adjustments.";
        }
        elsif ( lc( $a[2] ) eq "locationmap" ) {
            my $locationmapName = $name . "_map";

            if ( defined( $defs{$locationmapName} ) ) {
                return
"Device $locationmapName existing already, delete it first to have it re-created.";
            }
            else {
                my $sortby = AttrVal( $name, "sortby", -1 );
                $sortby++;

                # create new weblink device
                fhem "define $locationmapName weblink htmlCode {
'<ul style=\"width: 400px;; overflow: hidden;; height: 300px;;\">
<iframe name=\"$locationmapName\" src=\"https://www.google.com/maps/embed/v1/place?key=AIzaSyB66DvcpbXJ5eWgIkzxpUN2s_9l3_6fegM&q='
.ReadingsVal('$name','locationLat','')
.','
.ReadingsVal('$name','locationLong','')
.'&zoom=13\" width=\"480\" height=\"480\" frameborder=\"0\" style=\"border:0;; margin-top: -165px;; margin-left: -135px;;\">
</iframe>
</ul>'
}";
                fhem "attr $locationmapName alias Current Location";
                fhem
                  "attr $locationmapName comment Auto-created by GUEST module";
                fhem "attr $locationmapName group " . $attr{$name}{group}
                  if ( defined( $attr{$name}{group} ) );
                fhem "attr $locationmapName room " . $attr{$name}{room}
                  if ( defined( $attr{$name}{room} ) );
            }

            return "Weblink device $locationmapName was created.";
        }
    }

    # return usage hint
    else {
        return $usage;
    }

    return undef;
}

############################################################################################################
#
#   Begin of helper functions
#
############################################################################################################

###################################
sub GUEST_AutoGone($;$) {
    my ( $mHash, @a ) = @_;
    my $hash = ( $mHash->{HASH} ) ? $mHash->{HASH} : $mHash;
    my $name = $hash->{NAME};

    RESIDENTStk_RemoveInternalTimer( "AutoGone", $hash );

    if ( ReadingsVal( $name, "state", "home" ) eq "absent" ) {
        my ( $date, $time, $y, $m, $d, $hour, $min, $sec, $timestamp,
            $timeDiff );
        my $timestampNow = gettimeofday();
        my $timeout      = (
            defined( $attr{$name}{rg_autoGoneAfter} )
            ? $attr{$name}{rg_autoGoneAfter}
            : "16"
        );

        ( $date, $time ) = split( ' ', $hash->{READINGS}{state}{TIME} );
        ( $y,    $m,   $d )   = split( '-', $date );
        ( $hour, $min, $sec ) = split( ':', $time );
        $m -= 01;
        $timestamp = timelocal( $sec, $min, $hour, $d, $m, $y );
        $timeDiff = $timestampNow - $timestamp;

        if ( $timeDiff >= $timeout * 3600 ) {
            Log3 $name, 3,
              "GUEST $name: AutoGone timer changed state to 'gone'";
            GUEST_Set( $hash, $name, "silentSet", "state", "gone" );
        }
        else {
            my $runtime = $timestamp + $timeout * 3600;
            Log3 $name, 4, "GUEST $name: AutoGone timer scheduled: $runtime";
            RESIDENTStk_InternalTimer( "AutoGone", $runtime, "GUEST_AutoGone",
                $hash, 1 );
        }
    }

    return undef;
}

###################################
sub GUEST_DurationTimer($;$) {
    my ( $mHash, @a ) = @_;
    my $hash         = ( $mHash->{HASH} ) ? $mHash->{HASH} : $mHash;
    my $name         = $hash->{NAME};
    my $state        = ReadingsVal( $name, "state", "initialized" );
    my $silent       = ( defined( $a[0] ) && $a[0] eq "1" ) ? 1 : 0;
    my $timestampNow = gettimeofday();
    my $diff;
    my $durPresence = "0";
    my $durAbsence  = "0";
    my $durSleep    = "0";

    RESIDENTStk_RemoveInternalTimer( "DurationTimer", $hash );

    if ( !defined( $attr{$name}{rg_noDuration} )
        || $attr{$name}{rg_noDuration} == 0 )
    {

        # presence timer
        if (   ReadingsVal( $name, "presence", "absent" ) eq "present"
            && ReadingsVal( $name, "lastArrival", "-" ) ne "-" )
        {
            $durPresence =
              $timestampNow -
              time_str2num( ReadingsVal( $name, "lastArrival", "" ) );
        }

        # absence timer
        if (   ReadingsVal( $name, "presence", "present" ) eq "absent"
            && ReadingsVal( $name, "lastDeparture", "-" ) ne "-" )
        {
            $durAbsence =
              $timestampNow -
              time_str2num( ReadingsVal( $name, "lastDeparture", "" ) );
        }

        # sleep timer
        if (   ReadingsVal( $name, "state", "home" ) eq "asleep"
            && ReadingsVal( $name, "lastSleep", "-" ) ne "-" )
        {
            $durSleep =
              $timestampNow -
              time_str2num( ReadingsVal( $name, "lastSleep", "" ) );
        }

        my $durPresence_hr =
          ( $durPresence > 0 )
          ? RESIDENTStk_sec2time($durPresence)
          : "00:00:00";
        my $durPresence_cr =
          ( $durPresence > 60 ) ? int( $durPresence / 60 + 0.5 ) : 0;
        my $durAbsence_hr =
          ( $durAbsence > 0 ) ? RESIDENTStk_sec2time($durAbsence) : "00:00:00";
        my $durAbsence_cr =
          ( $durAbsence > 60 ) ? int( $durAbsence / 60 + 0.5 ) : 0;
        my $durSleep_hr =
          ( $durSleep > 0 ) ? RESIDENTStk_sec2time($durSleep) : "00:00:00";
        my $durSleep_cr = ( $durSleep > 60 ) ? int( $durSleep / 60 + 0.5 ) : 0;

        readingsBeginUpdate($hash) if ( !$silent );
        readingsBulkUpdate( $hash, "durTimerPresence_cr", $durPresence_cr )
          if ( ReadingsVal( $name, "durTimerPresence_cr", "" ) ne
            $durPresence_cr );
        readingsBulkUpdate( $hash, "durTimerPresence", $durPresence_hr )
          if (
            ReadingsVal( $name, "durTimerPresence", "" ) ne $durPresence_hr );
        readingsBulkUpdate( $hash, "durTimerAbsence_cr", $durAbsence_cr )
          if (
            ReadingsVal( $name, "durTimerAbsence_cr", "" ) ne $durAbsence_cr );
        readingsBulkUpdate( $hash, "durTimerAbsence", $durAbsence_hr )
          if ( ReadingsVal( $name, "durTimerAbsence", "" ) ne $durAbsence_hr );
        readingsBulkUpdate( $hash, "durTimerSleep_cr", $durSleep_cr )
          if ( ReadingsVal( $name, "durTimerSleep_cr", "" ) ne $durSleep_cr );
        readingsBulkUpdate( $hash, "durTimerSleep", $durSleep_hr )
          if ( ReadingsVal( $name, "durTimerSleep", "" ) ne $durSleep_hr );
        readingsEndUpdate( $hash, 1 ) if ( !$silent );
    }

    RESIDENTStk_InternalTimer( "DurationTimer", $timestampNow + 60,
        "GUEST_DurationTimer", $hash, 1 )
      if ( $state ne "none" );

    return undef;
}

###################################
sub GUEST_SetLocation($$$;$$$$$$) {
    my ( $name, $location, $trigger, $id, $time, $lat, $long, $address,
        $device ) = @_;
    my $hash         = $defs{$name};
    my $state        = ReadingsVal( $name, "state", "initialized" );
    my $presence     = ReadingsVal( $name, "presence", "present" );
    my $currLocation = ReadingsVal( $name, "location", "-" );
    my $currWayhome  = ReadingsVal( $name, "wayhome", "0" );
    my $currLat      = ReadingsVal( $name, "locationLat", "-" );
    my $currLong     = ReadingsVal( $name, "locationLong", "-" );
    my $currAddr     = ReadingsVal( $name, "locationAddr", "" );
    $id   = "-" if ( !$id   || $id eq "" );
    $lat  = "-" if ( !$lat  || $lat eq "" );
    $long = "-" if ( !$long || $long eq "" );
    $address = "" if ( !$address );
    $time    = "" if ( !$time );
    $device  = "" if ( !$device );

    Log3 $name, 5,
"GUEST $name: received location information: id=$id name=$location trig=$trigger date=$time lat=$lat long=$long address:$address device=$device";

    my $searchstring;

    readingsBeginUpdate($hash);

    # read attributes
    my @location_home =
      split( ' ', AttrVal( $name, "rg_locationHome", "home" ) );
    my @location_underway =
      split( ' ', AttrVal( $name, "rg_locationUnderway", "underway" ) );
    my @location_wayhome =
      split( ' ', AttrVal( $name, "rg_locationWayhome", "wayhome" ) );

    $searchstring = quotemeta($location);

    # update locationPresence
    readingsBulkUpdate( $hash, "locationPresence", "present" )
      if ( $trigger == 1 );
    readingsBulkUpdate( $hash, "locationPresence", "absent" )
      if ( $trigger == 0 );

    # check for implicit state change
    #
    my $stateChange = 0;

    # home
    if ( $location eq "home" || grep( m/^$searchstring$/, @location_home ) ) {
        Log3 $name, 5, "GUEST $name: received signal from home location";

        # home
        if (   $state ne "home"
            && $state ne "gotosleep"
            && $state ne "asleep"
            && $state ne "awoken"
            && $trigger eq "1" )
        {
            $stateChange = 1;
        }

        # absent
        elsif ($state ne "gone"
            && $state ne "none"
            && $state ne "absent"
            && $trigger eq "0" )
        {
            $stateChange = 2;
        }

    }

    # underway
    elsif ($location eq "underway"
        || $location eq "wayhome"
        || grep( m/^$searchstring$/, @location_underway )
        || grep( m/^$searchstring$/, @location_wayhome ) )
    {
        Log3 $name, 5, "GUEST $name: received signal from underway location";

        # absent
        $stateChange = 2
          if ( $state ne "gone"
            && $state ne "none"
            && $state ne "absent" );
    }

    # wayhome
    if (
        $location eq "wayhome"
        || ( grep( m/^$searchstring$/, @location_wayhome )
            && $trigger eq "0" )
      )
    {
        Log3 $name, 5, "GUEST $name: wayhome signal received";

        # wayhome=true
        if (
            (
                   ( $location eq "wayhome" && $trigger eq "1" )
                || ( $location ne "wayhome" && $trigger eq "0" )
            )
            && ReadingsVal( $name, "wayhome", "0" ) ne "1"
          )
        {
            Log3 $name, 3, "GUEST $name: on way back home from $location";
            readingsBulkUpdate( $hash, "wayhome", "1" );
        }

        # wayhome=false
        elsif ($location eq "wayhome"
            && $trigger eq "0"
            && ReadingsVal( $name, "wayhome", "0" ) ne "0" )
        {
            Log3 $name, 3,
              "GUEST $name: seems not to be on way back home anymore";
            readingsBulkUpdate( $hash, "wayhome", "0" );
        }

    }

    # activate wayhome tracing when reaching another location while wayhome=1
    elsif ( $stateChange == 0 && $trigger == 1 && $currWayhome == 1 ) {
        Log3 $name, 3,
          "GUEST $name: seems to stay at $location before coming home";
        readingsBulkUpdate( $hash, "wayhome", "2" );
    }

    # revert wayhome during active wayhome tracing
    elsif ( $stateChange == 0 && $trigger == 0 && $currWayhome == 2 ) {
        Log3 $name, 3, "GUEST $name: finally on way back home from $location";
        readingsBulkUpdate( $hash, "wayhome", "1" );
    }

    my $currLongDiff = 0;
    my $currLatDiff  = 0;
    $currLongDiff =
      maxNum( ReadingsVal( $name, "lastLocationLong", 0 ), $currLong ) -
      minNum( ReadingsVal( $name, "lastLocationLong", 0 ), $currLong )
      if ( $currLong ne "-" );
    $currLatDiff =
      maxNum( ReadingsVal( $name, "lastLocationLat", 0 ), $currLat ) -
      minNum( ReadingsVal( $name, "lastLocationLat", 0 ), $currLat )
      if ( $currLat ne "-" );

    if (
        $trigger == 1
        && (   $stateChange > 0
            || ReadingsVal( $name, "lastLocation", "-" ) ne $currLocation
            || $currLongDiff > 0.00002
            || $currLatDiff > 0.00002 )
      )
    {
        Log3 $name, 5, "GUEST $name: archiving last known location";
        readingsBulkUpdate( $hash, "lastLocationLat",  $currLat );
        readingsBulkUpdate( $hash, "lastLocationLong", $currLong );
        readingsBulkUpdate( $hash, "lastLocationAddr", $currAddr )
          if ( $currAddr ne "" );
        readingsBulkUpdate( $hash, "lastLocation", $currLocation );
    }

    readingsBulkUpdate( $hash, "locationLat",  $lat );
    readingsBulkUpdate( $hash, "locationLong", $long );

    if ( $address ne "" ) {
        readingsBulkUpdate( $hash, "locationAddr", $address );
    }
    elsif ( $currAddr ne "" ) {
        readingsBulkUpdate( $hash, "locationAddr", "-" );
    }

    readingsBulkUpdate( $hash, "location", $location );

    readingsEndUpdate( $hash, 1 );

    # trigger state change
    if ( $stateChange > 0 ) {
        Log3 $name, 4,
          "GUEST $name: implicit state change caused by location " . $location;

        GUEST_Set( $hash, $name, "silentSet", "state", "home" )
          if $stateChange == 1;
        GUEST_Set( $hash, $name, "silentSet", "state", "absent" )
          if $stateChange == 2;
    }

}

###################################
sub GUEST_StartInternalTimers($$) {
    my ($hash) = @_;

    GUEST_AutoGone($hash);
    GUEST_DurationTimer($hash);
}

1;

=pod
=item helper
=item summary special virtual device to represent a guest of your home
=item summary_DE spezielles virtuelles Device, welches einen Gast zu Hause repr&auml;sentiert
=begin html

    <a name="GUEST" id="GUEST"></a>
    <h3>GUEST</h3>
    <ul>
      <a name="GUESTdefine" id="GUESTdefine"></a> <b>Define</b>
      <ul>
        <code>define &lt;rg_GuestName&gt; GUEST [&lt;device name(s) of resident group(s)&gt;]</code><br>
        <br>
        Provides a special virtual device to represent a guest of your home.<br>
        Based on the current state and other readings, you may trigger other actions within FHEM.<br>
        <br>
        Used by superior module <a href="#RESIDENTS">RESIDENTS</a> but may also be used stand-alone.<br>
        <br />
        Use comma separated list of resident device names for multi-membership (see example below).<br />
        <br>
        Example:<br>
        <ul>
          <code># Standalone<br>
          define rg_Guest GUEST<br>
          <br>
          # Typical group member<br>
          define rg_Guest GUEST rgr_Residents # to be member of resident group rgr_Residents<br>
          <br>
          # Member of multiple groups<br>
          define rg_Guest GUEST rgr_Residents,rgr_Guests # to be member of resident group rgr_Residents and rgr_Guests</code>
        </ul>
      </ul><br>
      <ul>
        Please note the RESIDENTS group device needs to be existing before a GUEST device can become a member of it.
      </ul><br>
      <br>
      <br>
      <a name="GUESTset" id="GUESTset"></a> <b>Set</b>
      <ul>
        <code>set &lt;rg_GuestName&gt; &lt;command&gt; [&lt;parameter&gt;]</code><br>
        <br>
        Currently, the following commands are defined.<br>
        <ul>
          <li>
            <b>location</b> &nbsp;&nbsp;-&nbsp;&nbsp; sets reading 'location'; see attribute rg_locations to adjust list shown in FHEMWEB
          </li>
          <li>
            <b>mood</b> &nbsp;&nbsp;-&nbsp;&nbsp; sets reading 'mood'; see attribute rg_moods to adjust list shown in FHEMWEB
          </li>
          <li>
            <b>state</b> &nbsp;&nbsp;home,gotosleep,asleep,awoken,absent,none&nbsp;&nbsp; switch between states; see attribute rg_states to adjust list shown in FHEMWEB
          </li>
          <li>
            <b>create</b>
             <li><i>locationMap</i>&nbsp;&nbsp; add a pre-configured weblink device using showing a Google Map if readings locationLat+locationLong are present.</li>
             <li><i>wakeuptimer</i>&nbsp;&nbsp; add several pre-configurations provided by RESIDENTS Toolkit. See separate section in <a href="#RESIDENTS">RESIDENTS module commandref</a> for details.</li>
          </li>
        </ul>
        <ul>
            <u>Note:</u> If you would like to restrict access to admin set-commands (-> create) you may set your FHEMWEB instance's attribute allowedCommands like 'set,set-user'.
            The string 'set-user' will ensure only non-admin set-commands can be executed when accessing FHEM using this FHEMWEB instance.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Possible states and their meaning</u><br>
        <br>
        <ul>
          This module differs between 6 states:<br>
          <br>
          <ul>
            <li>
              <b>home</b> - individual is present at home and awake
            </li>
            <li>
              <b>gotosleep</b> - individual is on it's way to bed
            </li>
            <li>
              <b>asleep</b> - individual is currently sleeping
            </li>
            <li>
              <b>awoken</b> - individual just woke up from sleep
            </li>
            <li>
              <b>absent</b> - individual is not present at home but will be back shortly
            </li>
            <li>
              <b>none</b> - guest device is disabled
            </li>
          </ul>
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Presence correlation to location</u><br>
        <br>
        <ul>
          Under specific circumstances, changing state will automatically change reading 'location' as well.<br>
          <br>
          Whenever presence state changes from 'absent' to 'present', the location is set to 'home'. If attribute rg_locationHome was defined, first location from it will be used as home location.<br>
          <br>
          Whenever presence state changes from 'present' to 'absent', the location is set to 'underway'. If attribute rg_locationUnderway was defined, first location from it will be used as underway location.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Auto Gone</u><br>
        <br>
        <ul>
          Whenever an individual is set to 'absent', a trigger is started to automatically change state to 'gone' after a specific timeframe.<br>
          Default value is 16 hours.<br>
          <br>
          This behaviour can be customized by attribute rg_autoGoneAfter.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Synchronizing presence with other ROOMMATE or GUEST devices</u><br>
        <br>
        <ul>
          If you always leave or arrive at your house together with other roommates or guests, you may enable a synchronization of your presence state for certain individuals.<br>
          By setting attribute rg_passPresenceTo, those individuals will follow your presence state changes to 'home', 'absent' or 'gone' as you do them with your own device.<br>
          <br>
          Please note that individuals with current state 'none' or 'gone' (in case of roommates) will not be touched.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Location correlation to state</u><br>
        <br>
        <ul>
          Under specific circumstances, changing location will have an effect on the actual state as well.<br>
          <br>
          Whenever location is set to 'home', the state is set to 'home' if prior presence state was 'absent'. If attribute rg_locationHome was defined, all of those locations will trigger state change to 'home' as well.<br>
          <br>
          Whenever location is set to 'underway', the state is set to 'absent' if prior presence state was 'present'. If attribute rg_locationUnderway was defined, all of those locations will trigger state change to 'absent' as well. Those locations won't appear in reading 'lastLocation'.<br>
          <br>
          Whenever location is set to 'wayhome', the reading 'wayhome' is set to '1' if current presence state is 'absent'. If attribute rg_locationWayhome was defined, LEAVING one of those locations will set reading 'wayhome' to '1' as well. So you actually have implicit and explicit options to trigger wayhome.<br>
          Arriving at home will reset the value of 'wayhome' to '0'.<br>
          <br>
          If you are using the <a href="#GEOFANCY">GEOFANCY</a> module, you can easily have your location updated with GEOFANCY events by defining a simple NOTIFY-trigger like this:<br>
          <br>
          <code>define n_rg_Guest.location notify geofancy:currLoc_Guest.* set rg_Guest:FILTER=location!=$EVTPART1 location $EVTPART1</code><br>
          <br>
          By defining geofencing zones called 'home' and 'wayhome' in the iOS app, you automatically get all the features of automatic state changes described above.
        </ul>
      </ul><br>
      <br>
      <a name="GUESTattr" id="GUESTattr"></a> <b>Attributes</b><br>
      <ul>
        <ul>
          <li>
            <b>rg_autoGoneAfter</b> - hours after which state should be auto-set to 'gone' when current state is 'absent'; defaults to 16 hours
          </li>
          <li>
            <b>rg_geofenceUUIDs</b> - comma separated list of device UUIDs updating their location via <a href="#GEOFANCY">GEOFANCY</a>. Avoids necessity for additional notify/DOIF/watchdog devices and can make GEOFANCY attribute <i>devAlias</i> obsolete. (using more than one UUID/device might not be a good idea as location my leap)
          </li>
          <li>
            <b>rg_locationHome</b> - locations matching these will be treated as being at home; first entry reflects default value to be used with state correlation; separate entries by space; defaults to 'home'
          </li>
          <li>
            <b>rg_locationUnderway</b> - locations matching these will be treated as being underway; first entry reflects default value to be used with state correlation; separate entries by comma or space; defaults to "underway"
          </li>
          <li>
            <b>rg_locationWayhome</b> - leaving a location matching these will set reading wayhome to 1; separate entries by space; defaults to "wayhome"
          </li>
          <li>
            <b>rg_locations</b> - list of locations to be shown in FHEMWEB; separate entries by comma only and do NOT use spaces
          </li>
          <li>
            <b>rg_moodDefault</b> - the mood that should be set after arriving at home or changing state from awoken to home
          </li>
          <li>
            <b>rg_moodSleepy</b> - the mood that should be set if state was changed to gotosleep or awoken
          </li>
          <li>
            <b>rg_moods</b> - list of moods to be shown in FHEMWEB; separate entries by comma only and do NOT use spaces
          </li>
          <li>
            <b>rg_noDuration</b> - may be used to disable duration timer calculation (see readings durTimer*)
          </li>
          <li>
            <b>rg_passPresenceTo</b> - synchronize presence state with other GUEST or GUEST devices; separte devices by space
          </li>
          <li>
            <b>rg_presenceDevices</b> - take over presence state from any other FHEM device. Separate more than one device with comma meaning ALL of them need to be either present or absent to trigger update of this ROOMMATE device.
          </li>
          <li>
            <b>rg_realname</b> - whenever GUEST wants to use the realname it uses the value of attribute alias or group; defaults to group
          </li>
          <li>
            <b>rg_showAllStates</b> - states 'asleep' and 'awoken' are hidden by default to allow simple gotosleep process via devStateIcon; defaults to 0
          </li>
          <li>
            <b>rg_states</b> - list of states to be shown in FHEMWEB; separate entries by comma only and do NOT use spaces; unsupported states will lead to errors though
          </li>
          <li>
            <b>rg_wakeupDevice</b> - reference to enslaved DUMMY devices used as a wake-up timer (part of RESIDENTS Toolkit's wakeuptimer)
          </li>
        </ul>
      </ul><br>
      <br>
      <br>
      <b>Generated Readings/Events:</b><br>
      <ul>
        <ul>
          <li>
            <b>durTimerAbsence</b> - timer to show the duration of absence from home in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>durTimerAbsence_cr</b> - timer to show the duration of absence from home in computer readable format (minutes)
          </li>
          <li>
            <b>durTimerPresence</b> - timer to show the duration of presence at home in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>durTimerPresence_cr</b> - timer to show the duration of presence at home in computer readable format (minutes)
          </li>
          <li>
            <b>durTimerSleep</b> - timer to show the duration of sleep in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>durTimerSleep_cr</b> - timer to show the duration of sleep in computer readable format (minutes)
          </li>
          <li>
            <b>lastArrival</b> - timestamp of last arrival at home
          </li>
          <li>
            <b>lastAwake</b> - timestamp of last sleep cycle end
          </li>
          <li>
            <b>lastDeparture</b> - timestamp of last departure from home
          </li>
          <li>
            <b>lastDurAbsence</b> - duration of last absence from home in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>lastDurAbsence_cr</b> - duration of last absence from home in computer readable format (minutes)
          </li>
          <li>
            <b>lastDurPresence</b> - duration of last presence at home in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>lastDurPresence_cr</b> - duration of last presence at home in computer readable format (minutes)
          </li>
          <li>
            <b>lastDurSleep</b> - duration of last sleep in human readable format (hours:minutes:seconds)
          </li>
          <li>
            <b>lastDurSleep_cr</b> - duration of last sleep in computer readable format (minutes)
          </li>
          <li>
            <b>lastLocation</b> - the prior location
          </li>
          <li>
            <b>lastMood</b> - the prior mood
          </li>
          <li>
            <b>lastSleep</b> - timestamp of last sleep cycle begin
          </li>
          <li>
            <b>lastState</b> - the prior state
          </li>
          <li>
            <b>lastWakeup</b> - time of last wake-up timer run
          </li>
          <li>
            <b>lastWakeupDev</b> - device name of last wake-up timer
          </li>
          <li>
            <b>location</b> - the current location
          </li>
          <li>
            <b>mood</b> - the current mood
          </li>
          <li>
            <b>nextWakeup</b> - time of next wake-up program run
          </li>
          <li>
            <b>nextWakeupDev</b> - device name for next wake-up program run
          </li>
          <li>
            <b>presence</b> - reflects the home presence state, depending on value of reading 'state' (can be 'present' or 'absent')
          </li>
          <li>
            <b>state</b> - reflects the current state
          </li>
          <li>
            <b>wakeup</b> - becomes '1' while a wake-up program of this resident is being executed
          </li>
          <li>
            <b>wayhome</b> - depending on current location, it can become '1' if individual is on his/her way back home
          </li>
          <li>
            <br>
            <br>
            The following readings will be set to '-' if state was changed to 'none':<br>
            lastArrival, lastDurAbsence, lastLocation, lastMood, location, mood
          </li>
        </ul>
      </ul>
    </ul>

=end html

=begin html_DE

    <a name="GUEST" id="GUEST"></a>
    <h3>GUEST</h3>
    <ul>
      <a name="GUESTdefine" id="GUESTdefine"></a> <b>Define</b>
      <ul>
        <code>define &lt;rg_FirstName&gt; GUEST [&lt;Device Name(n) der Bewohnergruppe(n)&gt;]</code><br>
        <br>
        Stellt ein spezielles virtuelles Device bereit, welches einen Gast zu Hause repr&auml;sentiert.<br>
        Basierend auf dem aktuellen Status und anderen Readings k&ouml;nnen andere Aktionen innerhalb von FHEM angestoßen werden.<br>
        <br>
        Wird vom &uuml;bergeordneten Modul <a href="#RESIDENTS">RESIDENTS</a> verwendet, kann aber auch einzeln benutzt werden.<br>
        <br />
        Bei Mitgliedschaft mehrerer Bewohnergruppen werden diese durch Komma getrennt angegeben (siehe Beispiel unten).<br />
        <br>
        Beispiele:<br>
        <ul>
          <code># Einzeln<br>
          define rg_Guest GUEST<br>
          <br>
          # Typisches Gruppenmitglied<br>
          define rg_Guest GUEST rgr_Residents # um Mitglied der Gruppe rgr_Residents zu sein<br>
          <br>
          # Mitglied in mehreren Gruppen<br>
          define rg_Guest GUEST rgr_Residents,rgr_Guests # um Mitglied der Gruppen rgr_Residents und rgr_Guests zu sein</code>
        </ul>
      </ul><br>
      <ul>
        Bitte beachten, dass das RESIDENTS Gruppen Device zun&auml;chst angelegt werden muss, bevor ein GUEST Objekt dort Mitglied werden kann.
      </ul><br>
      <br>
      <br>
      <a name="GUESTset" id="GUESTset"></a> <b>Set</b>
      <ul>
        <code>set &lt;rg_FirstName&gt; &lt;command&gt; [&lt;parameter&gt;]</code><br>
        <br>
        Momentan sind die folgenden Kommandos definiert.<br>
        <ul>
          <li>
            <b>location</b> &nbsp;&nbsp;-&nbsp;&nbsp; setzt das Reading 'location'; siehe auch Attribut rg_locations, um die in FHEMWEB angezeigte Liste anzupassen
          </li>
          <li>
            <b>mood</b> &nbsp;&nbsp;-&nbsp;&nbsp; setzt das Reading 'mood'; siehe auch Attribut rg_moods, um die in FHEMWEB angezeigte Liste anzupassen
          </li>
          <li>
            <b>state</b> &nbsp;&nbsp;home,gotosleep,asleep,awoken,absent,gone&nbsp;&nbsp; wechselt den Status; siehe auch Attribut rg_states, um die in FHEMWEB angezeigte Liste anzupassen
          </li>
          <li>
            <b>create</b>
             <li><i>locationMap</i>&nbsp;&nbsp; f&uuml;gt ein vorkonfiguriertes weblink Device hinzu, welches eine Google Map anzeigt, sofern die Readings locationLat+locationLong vorhanden sind.</li>
             <li><i>wakeuptimer</i>&nbsp;&nbsp; f&uuml;gt diverse Vorkonfigurationen auf Basis von RESIDENTS Toolkit hinzu. Siehe separate Sektion in der <a href="#RESIDENTS">RESIDENTS Modul Kommandoreferenz</a>.</li>
          </li>
        </ul>
        <ul>
            <u>Hinweis:</u> Sofern der Zugriff auf administrative set-Kommandos (-> create) eingeschr&auml;nkt werden soll, kann in einer FHEMWEB Instanz das Attribut allowedCommands &auml;hnlich wie 'set,set-user' erweitert werden.
            Die Zeichenfolge 'set-user' stellt dabei sicher, dass beim Zugriff auf FHEM &uuml;ber diese FHEMWEB Instanz nur nicht-administrative set-Kommandos ausgef&uuml;hrt werden k&ouml;nnen.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>M&ouml;gliche Status und ihre Bedeutung</u><br>
        <br>
        <ul>
          Dieses Modul unterscheidet 6 verschiedene Status:<br>
          <br>
          <ul>
            <li>
              <b>home</b> - Mitbewohner ist zu Hause und wach
            </li>
            <li>
              <b>gotosleep</b> - Mitbewohner ist auf dem Weg ins Bett
            </li>
            <li>
              <b>asleep</b> - Mitbewohner schl&auml;ft
            </li>
            <li>
              <b>awoken</b> - Mitbewohner ist gerade aufgewacht
            </li>
            <li>
              <b>absent</b> - Mitbewohner ist momentan nicht zu Hause, wird aber bald zur&uuml;ck sein
            </li>
            <li>
              <b>none</b> - Gast Device ist deaktiviert
            </li>
          </ul>
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Zusammenhang zwischen Anwesenheit/Presence und Aufenthaltsort/Location</u><br>
        <br>
        <ul>
          Unter bestimmten Umst&auml;nden f&uuml;hrt der Wechsel des Status auch zu einer Änderung des Readings 'location'.<br>
          <br>
          Wannimmer die Anwesenheit (bzw. das Reading 'presence') von 'absent' auf 'present' wechselt, wird 'location' auf 'home' gesetzt. Sofern das Attribut rg_locationHome gesetzt ist, wird die erste Lokation daraus anstelle von 'home' verwendet.<br>
          <br>
          Wannimmer die Anwesenheit (bzw. das Reading 'presence') von 'present' auf 'absent' wechselt, wird 'location' auf 'underway' gesetzt. Sofern das Attribut rg_locationUnderway gesetzt ist, wird die erste Lokation daraus anstelle von 'underway' verwendet.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Auto-Status 'gone'</u><br>
        <br>
        <ul>
          Immer wenn ein Mitbewohner auf 'absent' gesetzt wird, wird ein Z&auml;hler gestartet, der nach einer bestimmten Zeit den Status automatisch auf 'gone' setzt.<br>
          Der Standard ist nach 16 Stunden.<br>
          <br>
          Dieses Verhalten kann &uuml;ber das Attribut rg_autoGoneAfter angepasst werden.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Anwesenheit mit anderen GUEST oder ROOMMATE Devices synchronisieren</u><br>
        <br>
        <ul>
          Wenn Sie immer zusammen mit anderen Mitbewohnern oder G&auml;sten das Haus verlassen oder erreichen, k&ouml;nnen Sie ihren Status ganz einfach auf andere Mitbewohner &uuml;bertragen.<br>
          Durch das Setzen des Attributs rg_PassPresenceTo folgen die dort aufgef&uuml;hrten Mitbewohner ihren eigenen Status&auml;nderungen nach 'home', 'absent' oder 'gone'.<br>
          <br>
          Bitte beachten, dass Mitbewohner mit dem aktuellen Status 'none' oder 'gone' (im Falle von ROOMMATE Devices) nicht beachtet werden.
        </ul>
      </ul><br>
      <br>
      <ul>
        <u>Zusammenhang zwischen Aufenthaltsort/Location und Anwesenheit/Presence</u><br>
        <br>
        <ul>
          Unter bestimmten Umst&auml;nden hat der Wechsel des Readings 'location' auch einen Einfluss auf den tats&auml;chlichen Status.<br>
          <br>
          Immer wenn eine Lokation mit dem Namen 'home' gesetzt wird, wird auch der Status auf 'home' gesetzt, sofern die Anwesenheit bis dahin noch auf 'absent' stand. Sofern das Attribut rg_locationHome gesetzt wurde, so l&ouml;sen alle dort angegebenen Lokationen einen Statuswechsel nach 'home' aus.<br>
          <br>
          Immer wenn eine Lokation mit dem Namen 'underway' gesetzt wird, wird auch der Status auf 'absent' gesetzt, sofern die Anwesenheit bis dahin noch auf 'present' stand. Sofern das Attribut rg_locationUnderway gesetzt wurde, so l&ouml;sen alle dort angegebenen Lokationen einen Statuswechsel nach 'underway' aus. Diese Lokationen werden auch nicht in das Reading 'lastLocation' &uuml;bertragen.<br>
          <br>
          Immer wenn eine Lokation mit dem Namen 'wayhome' gesetzt wird, wird das Reading 'wayhome' auf '1' gesetzt, sofern die Anwesenheit zu diesem Zeitpunkt 'absent' ist. Sofern das Attribut rg_locationWayhome gesetzt wurde, so f&uuml;hrt das VERLASSEN einer dort aufgef&uuml;hrten Lokation ebenfalls dazu, dass das Reading 'wayhome' auf '1' gesetzt wird. Es gibt also 2 M&ouml;glichkeiten den Nach-Hause-Weg-Indikator zu beeinflussen (implizit und explizit).<br>
          Die Ankunft zu Hause setzt den Wert von 'wayhome' zur&uuml;ck auf '0'.<br>
          <br>
          Wenn Sie auch das <a href="#GEOFANCY">GEOFANCY</a> Modul verwenden, k&ouml;nnen Sie das Reading 'location' ganz einfach &uuml;ber GEOFANCY Ereignisse aktualisieren lassen. Definieren Sie dazu einen NOTIFY-Trigger wie diesen:<br>
          <br>
          <code>define n_rg_Manfred.location notify geofancy:currLoc_Manfred.* set rg_Manfred:FILTER=location!=$EVTPART1 location $EVTPART1</code><br>
          <br>
          Durch das Anlegen von Geofencing-Zonen mit den Namen 'home' und 'wayhome' in der iOS App werden zuk&uuml;nftig automatisch alle Status&auml;nderungen wie oben beschrieben durchgef&uuml;hrt.
        </ul>
      </ul><br>
      <br>
      <a name="GUESTattr" id="GUESTattr"></a> <b>Attribute</b><br>
      <ul>
        <ul>
          <li>
            <b>rg_autoGoneAfter</b> - Anzahl der Stunden, nach denen sich der Status automatisch auf 'gone' &auml;ndert, wenn der aktuellen Status 'absent' ist; Standard ist 36 Stunden
          </li>
          <li>
            <b>rg_geofenceUUIDs</b> - Mit Komma getrennte Liste von Ger&auml;te UUIDs, die ihren Standort &uuml;ber <a href="#GEOFANCY">GEOFANCY</a> aktualisieren. Vermeidet zus&auml;tzliche notify/DOIF/watchdog Ger&auml;te und kann als Ersatz f&uuml;r das GEOFANCY attribute <i>devAlias</i> dienen. (hier ehr als eine UUID/Device zu hinterlegen ist eher keine gute Idee da die Lokation dann wom&ouml;glich anf&auml;ngt zu springen)
          </li>
          <li>
            <b>rg_locationHome</b> - hiermit &uuml;bereinstimmende Lokationen werden als zu Hause gewertet; der erste Eintrag wird f&uuml;r das Zusammenspiel bei Status&auml;nderungen benutzt; mehrere Eintr&auml;ge durch Leerzeichen trennen; Standard ist 'home'
          </li>
          <li>
            <b>rg_locationUnderway</b> - hiermit &uuml;bereinstimmende Lokationen werden als unterwegs gewertet; der erste Eintrag wird f&uuml;r das Zusammenspiel bei Status&auml;nderungen benutzt; mehrere Eintr&auml;ge durch Leerzeichen trennen; Standard ist 'underway'
          </li>
          <li>
            <b>rg_locationWayhome</b> - das Verlassen einer Lokation, die hier aufgef&uuml;hrt ist, l&auml;sst das Reading 'wayhome' auf '1' setzen; mehrere Eintr&auml;ge durch Leerzeichen trennen; Standard ist "wayhome"
          </li>
          <li>
            <b>rg_locations</b> - Liste der in FHEMWEB anzuzeigenden Lokationsauswahlliste in FHEMWEB; mehrere Eintr&auml;ge nur durch Komma trennen und KEINE Leerzeichen verwenden
          </li>
          <li>
            <b>rg_moodDefault</b> - die Stimmung, die nach Ankunft zu Hause oder nach dem Statuswechsel von 'awoken' auf 'home' gesetzt werden soll
          </li>
          <li>
            <b>rg_moodSleepy</b> - die Stimmung, die nach Statuswechsel zu 'gotosleep' oder 'awoken' gesetzt werden soll
          </li>
          <li>
            <b>rg_moods</b> - Liste von Stimmungen, wie sie in FHEMWEB angezeigt werden sollen; mehrere Eintr&auml;ge nur durch Komma trennen und KEINE Leerzeichen verwenden
          </li>
          <li>
            <b>rg_noDuration</b> - deaktiviert die Berechnung der Zeitspannen (siehe Readings durTimer*)
          </li>
          <li>
            <b>rg_passPresenceTo</b> - synchronisiere die Anwesenheit mit anderen GUEST oder ROOMMATE Devices; mehrere Devices durch Leerzeichen trennen
          </li>
          <li>
            <b>rg_presenceDevices</b> - &uuml;bernehmen des presence Status von einem anderen FHEM Device. Bei mehreren Devices diese mit Komma trennen, um ein Update des GUEST Devices auszul&ouml;sen, sobald ALLE Devices entweder absent oder present sind.
          </li>
          <li>
            <b>rg_realname</b> - wo immer GUEST den richtigen Namen verwenden m&ouml;chte nutzt es den Wert des Attributs alias oder group; Standard ist group
          </li>
          <li>
            <b>rg_showAllStates</b> - die Status 'asleep' und 'awoken' sind normalerweise nicht immer sichtbar, um einen einfachen Zubettgeh-Prozess &uuml;ber das devStateIcon Attribut zu erm&ouml;glichen; Standard ist 0
          </li>
          <li>
            <b>rg_states</b> - Liste aller in FHEMWEB angezeigter Status; Eintrage nur mit Komma trennen und KEINE Leerzeichen benutzen; nicht unterst&uuml;tzte Status f&uuml;hren zu Fehlern
          </li>
          <li>
            <b>rg_wakeupDevice</b> - Referenz zu versklavten DUMMY Ger&auml;ten, welche als Wecker benutzt werden (Teil von RESIDENTS Toolkit's wakeuptimer)
          </li>
        </ul>
      </ul><br>
      <br>
      <br>
      <b>Generierte Readings/Events:</b><br>
      <ul>
        <ul>
          <li>
            <b>durTimerAbsence</b> - Timer, der die Dauer der Abwesenheit in normal lesbarem Format anzeigt (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>durTimerAbsence_cr</b> - Timer, der die Dauer der Abwesenheit in Computer lesbarem Format anzeigt (Minuten)
          </li>
          <li>
            <b>durTimerPresence</b> - Timer, der die Dauer der Anwesenheit in normal lesbarem Format anzeigt (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>durTimerPresence_cr</b> - Timer, der die Dauer der Anwesenheit in Computer lesbarem Format anzeigt (Minuten)
          </li>
          <li>
            <b>durTimerSleep</b> - Timer, der die Schlafdauer in normal lesbarem Format anzeigt (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>durTimerSleep_cr</b> - Timer, der die Schlafdauer in Computer lesbarem Format anzeigt (Minuten)
          </li>
          <li>
            <b>lastArrival</b> - Zeitstempel der letzten Ankunft zu Hause
          </li>
          <li>
            <b>lastAwake</b> - Zeitstempel des Endes des letzten Schlafzyklus
          </li>
          <li>
            <b>lastDeparture</b> - Zeitstempel des letzten Verlassens des Zuhauses
          </li>
          <li>
            <b>lastDurAbsence</b> - Dauer der letzten Abwesenheit in normal lesbarem Format (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>lastDurAbsence_cr</b> - Dauer der letzten Abwesenheit in Computer lesbarem Format (Minuten)
          </li>
          <li>
            <b>lastDurPresence</b> - Dauer der letzten Anwesenheit in normal lesbarem Format (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>lastDurPresence_cr</b> - Dauer der letzten Anwesenheit in Computer lesbarem Format (Minuten)
          </li>
          <li>
            <b>lastDurSleep</b> - Dauer des letzten Schlafzyklus in normal lesbarem Format (Stunden:Minuten:Sekunden)
          </li>
          <li>
            <b>lastDurSleep_cr</b> - Dauer des letzten Schlafzyklus in Computer lesbarem Format (Minuten)
          </li>
          <li>
            <b>lastLocation</b> - der vorherige Aufenthaltsort
          </li>
          <li>
            <b>lastMood</b> - die vorherige Stimmung
          </li>
          <li>
            <b>lastSleep</b> - Zeitstempel des Beginns des letzten Schlafzyklus
          </li>
          <li>
            <b>lastState</b> - der vorherige Status
          </li>
          <li>
            <b>lastWakeup</b> - Zeit der letzten Wake-up Timer Ausf&uuml;hring
          </li>
          <li>
            <b>lastWakeupDev</b> - Device Name des zuletzt verwendeten Wake-up Timers
          </li>
          <li>
            <b>location</b> - der aktuelle Aufenthaltsort
          </li>
          <li>
            <b>mood</b> - die aktuelle Stimmung
          </li>
          <li>
            <b>nextWakeup</b> - Zeit der n&auml;chsten Wake-up Timer Ausf&uuml;hrung
          </li>
          <li>
            <b>nextWakeupDev</b> - Device Name des als n&auml;chstes ausgef&auml;hrten Wake-up Timer
          </li>
          <li>
            <b>presence</b> - gibt den zu Hause Status in Abh&auml;ngigkeit des Readings 'state' wieder (kann 'present' oder 'absent' sein)
          </li>
          <li>
            <b>state</b> - gibt den aktuellen Status wieder
          </li>
          <li>
            <b>wakeup</b> - hat den Wert '1' w&auml;hrend ein Weckprogramm dieses Bewohners ausgef&uuml;hrt wird
          </li>
          <li>
            <b>wayhome</b> - abh&auml;ngig vom aktullen Aufenthaltsort, kann der Wert '1' werden, wenn die Person auf dem weg zur&uuml;ck nach Hause ist
          </li>
          <li>
            <br>
            Die folgenden Readings werden auf '-' gesetzt, sobald der Status auf 'none' steht:<br>
            lastArrival, lastDurAbsence, lastLocation, lastMood, location, mood
          </li>
        </ul>
      </ul>
    </ul>

=end html_DE

=cut
