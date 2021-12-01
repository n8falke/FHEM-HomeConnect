=head1
        48_HomeConnect.pm

        Version 1.1

=head1 SYNOPSIS
        Bosch Siemens Home Connect Modul for FHEM
        contributed by Stefan Willmeroth 09/2016

=head1 DESCRIPTION
        98_HomeConnect handle individual Home Connect devices via the
        96_HomeConnectConnection

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
=cut

package main;

use strict;
use warnings;
use JSON;
use Scalar::Util qw(looks_like_number);

use vars qw(%defs);
require HttpUtils;

##############################################
my %HomeConnect_Iconmap = (
  "Dishwasher"    => "scene_dishwasher",
  "Oven"          => "scene_baking_oven",
  "FridgeFreezer" => "scene_wine_cellar",	#fixme
  "Washer"        => "scene_washing_machine",
  "Dryer"         => "scene_clothes_dryer",
  "CoffeeMaker"   => "max_heizungsthermostat"   #fixme
);

my @HomeConnect_SettablePgmOptions = (
  "BSH.Common.Option.StartInRelative",
  "Cooking.Oven.Option.SetpointTemperature",
  "ConsumerProducts.CoffeeMaker.Option.FillQuantity",
  "ConsumerProducts.CoffeeMaker.Option.BeanAmount",
  "ConsumerProducts.CoffeeMaker.Option.CoffeeTemperature",
  "ConsumerProducts.CoffeeMaker.Option.BeanContainerSelection",
);

##############################################
sub HomeConnect_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "HomeConnect_Set";
  $hash->{DefFn}     = "HomeConnect_Define";
  $hash->{GetFn}     = "HomeConnect_Get";
  $hash->{AttrList}  = "disable:0,1 " .
                       "updateTimer " .
                       "stateFormat " .
                       $readingFnAttributes;
    return;
}

###################################
sub HomeConnect_Set($@)
{
  my ($hash, @a) = @_;

  my $haId = $hash->{haId};
  my $cmdPrefix = $hash->{commandPrefix};
  my $programs = $hash->{programs};

  if (!defined($programs)) {$programs="";}

  my $remoteStartAllowed = ReadingsVal($hash->{NAME}, "BSH.Common.Status.RemoteControlStartAllowed","0");
  my $operationState = ReadingsVal($hash->{NAME}, "BSH.Common.Status.OperationState","0");

  my $pgmRunning =($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
        $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
        $operationState eq "BSH.Common.EnumType.OperationState.Run");

  my $availableCmds;
  my $availableOpts="";
  my $availableSets="";

  if (defined($hash->{READINGS})) {
    foreach my $reading (keys %{$hash->{READINGS}}) {
      if (index ($reading,".Option.")>0 && grep( /^$reading$/, @HomeConnect_SettablePgmOptions )) {
        $availableOpts .= " ".$reading;
      }
      if (index ($reading,".Setting.")>0) {
        $availableSets .= " ".$reading;
      }
    }
  }

  if (!defined $hash->{type}) {
    if (Value($hash->{hcconn}) ne "Logged in") {
      $availableCmds = "init";
    }
  } else {
    if ($pgmRunning) {
      $availableCmds = "stopProgram";
    } elsif ($remoteStartAllowed) {
      $availableCmds = "startProgram";
    }
    $availableCmds.=" requestSettings BSH.Common.Root.SelectedProgram:$programs requestProgramOptions:$programs";
    $availableCmds.=$availableOpts if (length($availableOpts)>0);
    $availableCmds.=$availableSets if (length($availableSets)>0);
  }

  return "no set value specified" if(int(@a) < 2);
  return $availableCmds if($a[1] eq "?");

  shift @a;
  my $command = shift @a;

  Log3 $hash->{NAME}, 3, "$hash->{NAME}: set command: $command";

  ## Start a program
  if($command eq "startProgram") {
    return "A program is already running" if ($pgmRunning);

    return "Please enable remote start on your appliance to start a program" if (!$remoteStartAllowed);

    my $pgm = shift @a;
    if (!defined $pgm) {
      $pgm = ReadingsVal($hash->{NAME},"BSH.Common.Root.SelectedProgram",undef);
    }
    if (!defined $pgm || index($programs,$pgm) == -1) {
      return "Unknown program - choose one of $programs";
    }

    my $options="";
    # Use  default options of program, so a swith to new program can work
    # foreach my $key ( @HomeConnect_SettablePgmOptions ) {
    #   my $optval = ReadingsVal($hash->{NAME},$key,undef);
    #   if (defined $optval) {
    #     my @a = split("[ \t][ \t]*", $optval);
    #     $options .= "," if (length($options)>0);
    #     if (looks_like_number($a[0])) {
    #       $options .= "{\"key\":\"$key\",\"value\":$a[0]";
    #     } else {
    #       $options .= "{\"key\":\"$key\",\"value\":\"$a[0]\"";
    #     }
    #     $options .= ",\"unit\":\"$a[1]\"" if defined $a[1];
    #     $options .= "}";
    #   }
    # }

    # start a program
    my $data = {
      callback => \&HomeConnect_Response,
      uri => "/api/homeappliances/$haId/programs/active",
      data => "{\"data\":{\"key\":\"$cmdPrefix$pgm\",\"options\":[$options]}}"
    };
    HomeConnectConnection_request($hash, $data);
  }
  ## Stop current program
  if($command eq "stopProgram") {
    return "No program is running" if (!$pgmRunning);
    my $data = {
      callback => \&HomeConnect_Response,
      uri => "/api/homeappliances/$haId/programs/active"
    };
    HomeConnectConnection_delrequest($hash, $data);
  }
  ## Set options, update current program if needed
  if(index($availableOpts,$command)>-1) {
    my $optval = shift @a;
    my $optunit = shift @a;
    if (!defined $optval) {
      return "Please enter a new option value";
    }

    # do not set reading, status reports will show changes
    # my $newreading = $optval;
    # $newreading .= " ".$optunit if (defined $optunit);
    # readingsBeginUpdate($hash);
    # readingsBulkUpdate($hash, $command, $newreading);
    # readingsEndUpdate($hash, 1);

    # quote param if not number
    $optval = '"' . $optval . '"' if !looks_like_number($optval);
    my $json = "{\"data\":{\"key\":\"$command\",\"value\":$optval";
    $json .= ",\"unit\":\"$optunit\"" if (defined $optunit);
    $json .= "}}";
    # set option "active" when program is running (supported for oven)
    # or "selected" if program not running
    my $data = {
      callback => \&HomeConnect_Response,
      uri => $pgmRunning ? "/api/homeappliances/$haId/programs/active/options/$command"
                         : "/api/homeappliances/$haId/programs/selected/options/$command",
      data => $json
    };
    HomeConnectConnection_request($hash, $data);
  }

  ## Change settings
  if(index($availableSets,$command)>-1) {
    my $setval = shift @a;
    my $setunit = shift @a;
    if (!defined $setval) {
      return "Please enter a new setting value";
    }
    $setval = "\"$setval\"" if (!looks_like_number($setval));
    # workaround: fix booleans
    $setval = "1" eq $setval ? "true":"false" if (!defined $setunit && ("0" eq $setval || "1" eq $setval));

    # send the update
    my $json = "{\"data\":{\"key\":\"$command\",\"value\":$setval";
    $json .= ",\"unit\":\"$setunit\"" if (defined $setunit);
    $json .= "}}";
    my $data = {
      callback => \&HomeConnect_Response,
      uri => "/api/homeappliances/$haId/settings/$command",
      data => $json
    };
    HomeConnectConnection_request($hash,$data);
  }
  ## Connect to Home Connect server, update status
  if($command eq "init") {
    return HomeConnect_Init($hash);
  }
  ## Select a program
  if($command eq "BSH.Common.Root.SelectedProgram") {
    my $pgm = shift @a;
    if (!defined $pgm || index($programs,$pgm) == -1) {
      return "Unknown program $pgm, choose one of $programs";
    }

    my $cmdPrefix = $hash->{commandPrefix};
    my $data = {
      callback => \&HomeConnect_Response,
      uri => "/api/homeappliances/$haId/programs/selected",
      data => "{\"data\":{\"key\":\"$cmdPrefix$pgm\"}}"
    };
    HomeConnectConnection_request($hash,$data);
  }
  ## Request options for selected program
  if($command eq "requestProgramOptions") {
    my $pgm = shift @a;
    if (!defined $pgm || index($programs,$pgm) == -1) {
      return "Unknown program - choose one of $programs";
    }
    HomeConnect_GetProgramOptions($hash,$pgm);
  }
  ## Request appliance settings
  if($command eq "requestSettings") {
    HomeConnect_GetSettings($hash);
    HomeConnect_GetPrograms($hash);
  }
}

#####################################
sub HomeConnect_Response()
{
  my ($hash, $data) = @_;
  if (defined $data && length ($data) >0) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: response $data";

    my $JSON = JSON->new->utf8(0)->allow_nonref;
    my $parsed = eval {$JSON->decode($data)};
    if($@){
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error: $@";
      return;
    }
  }
}

#####################################
sub HomeConnect_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $u = "wrong syntax: define <dev-name> HomeConnect <conn-name> <haId> to add appliances";

  return $u if(int(@a) < 4);

  $hash->{hcconn} = $a[2];
  $hash->{haId} = $a[3];

  #### Delay init if not yet connected
  return undef if(Value($hash->{hcconn}) ne "Logged in");

  return HomeConnect_Init($hash);
}

#####################################
sub HomeConnect_Init($)
{
  #### Read list of appliances, find my haId 
  my ($hash) = @_;  
  my $data = {
    callback => \&HomeConnect_ResponseInit,
    uri => "/api/homeappliances"
  };
  HomeConnectConnection_request($hash,$data);
}

#####################################
sub HomeConnect_ResponseInit
{
  my ($hash, $data) = @_;
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  if (!defined $data) {
    return "Failed to connect to HomeConnect API, see log for details";
  }

  Log3 $hash->{NAME}, 4, "$hash->{NAME}: init response $data";

  my $appliances = eval {$JSON->decode ($data)};
  if($@){
    Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting appliances: $@";
    return;
  }

  for (my $i = 0; 1; $i++) {
    my $appliance = $appliances->{data}->{homeappliances}[$i];
    if (!defined $appliance) { last };
    if ($hash->{haId} eq $appliance->{haId}) {
      $hash->{aliasname} = $appliance->{name};
      $hash->{type} = $appliance->{type};
      $hash->{brand} = $appliance->{brand};
      $hash->{vib} = $appliance->{vib};
      $hash->{connected} = $appliance->{connected};
      Log3 $hash->{NAME}, 3, "$hash->{NAME}: defined as HomeConnect $hash->{type} $hash->{brand} $hash->{vib}";

      my $icon = $HomeConnect_Iconmap{$appliance->{type}};

      $attr{$hash->{NAME}}{icon} = $icon if (!defined $attr{$hash->{NAME}}{icon} && defined $icon);
      $attr{$hash->{NAME}}{alias} = $hash->{aliasname} if (!defined $attr{$hash->{NAME}}{alias} && defined $hash->{aliasname});
      $attr{$hash->{NAME}}{webCmd} = "BSH.Common.Root.SelectedProgram:startProgram:stopProgram" 
                   if (!defined $attr{$hash->{NAME}}{webCmd} && "FridgeFreezer" ne $hash->{type});

      HomeConnect_GetPrograms($hash);
      HomeConnect_UpdateStatus($hash);
      RemoveInternalTimer($hash);
      HomeConnect_CloseEventChannel($hash);
      HomeConnect_Timer($hash);
      return;
    }
  }
  Log3 $hash->{NAME}, 3, "$hash->{NAME}: Specified appliance with haId $hash->{haId} not found";
}

#####################################
sub HomeConnect_Undef($$)
{
   my ( $hash, $arg ) = @_;

   RemoveInternalTimer($hash);
   HomeConnect_CloseEventChannel($hash);
   Log3 $hash->{NAME}, 3, "$hash->{NAME}: --- removed ---";
   return undef;
}

#####################################
sub HomeConnect_Get($@)
{
  my ($hash, @args) = @_;

  return 'HomeConnect_Get needs two arguments' if (@args != 2);

  my $get = $args[1];
  my $val = $hash->{Invalid};

  return "HomeConnect_Get: not supported";
}

#####################################
sub HomeConnect_Timer
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  my $updateTimer = AttrVal($name, "updateTimer", 5);

  if (defined $hash->{conn} and AttrVal($name, "disable", 0) == 0) {
    HomeConnect_ReadEventChannel($hash);
  }
  # check if still connected
  if (!defined $hash->{conn} and AttrVal($name, "disable", 0) == 0) {
    # a new connection attempt is needed
    my $retryCounter = defined($hash->{retrycounter}) ? $hash->{retrycounter} : 0;
    if ($retryCounter == 0) {
      # first try
      HomeConnect_ConnectEventChannel($hash);
      InternalTimer( gettimeofday() + $updateTimer, "HomeConnect_Timer", $hash, 0);
    } else {
      # add an extra wait time
      InternalTimer( gettimeofday() + (($retryCounter) * 300), "HomeConnect_WaitTimer", $hash, 0);
    }
    $retryCounter++;
    $hash->{retrycounter} = $retryCounter;
  } else {
    # all good
    InternalTimer( gettimeofday() + $updateTimer, "HomeConnect_Timer", $hash, 0);
  }
}

#####################################
sub HomeConnect_WaitTimer
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  my $updateTimer = AttrVal($name, "updateTimer", 10);

  if (!defined $hash->{conn}) {
    # a new connection attempt is needed
    HomeConnect_ConnectEventChannel($hash);
  }
  InternalTimer( gettimeofday() + $updateTimer, "HomeConnect_Timer", $hash, 0);
}

#####################################
sub HomeConnect_GetProgramOptions
{
  my ($hash, $program) = @_;
  
  my $haId = $hash->{haId};
  my $cmdPrefix = $hash->{commandPrefix};

  my $data = {
    callback => \&HomeConnect_ResponseGetProgramOptions,
    uri => "/api/homeappliances/$haId/programs/available/$cmdPrefix$program"
  };
  HomeConnectConnection_request($hash, $data);
}

#####################################
sub HomeConnect_ResponseGetProgramOptions 
{
  my ($hash, $json) = @_;

  if (defined $json) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: program options response $json";

    my $JSON = JSON->new->utf8(0)->allow_nonref;
    my $parsed = eval {$JSON->decode ($json)};
    if($@){
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting options: $@";
    } else {
      my %readings = ();
      HomeConnect_parseOptionsToHash2(\%readings,$parsed);

      readingsBeginUpdate($hash);
      for my $get (keys %readings) {
        readingsBulkUpdate($hash, $get, $readings{$get});
      }
      readingsEndUpdate($hash, 1);
    }
  }
}

#####################################
sub HomeConnect_GetSettings
{
  my ($hash, $program) = @_;
  my $data = {
    callback => \&HomeConnect_ResponseGetSettings,
    uri => "/api/homeappliances/$hash->{haId}/settings"
  };
  HomeConnectConnection_request($hash,$data);
}

#####################################
sub HomeConnect_ResponseGetSettings
{
  my ($hash, $json) = @_;

  if (defined $json) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: get settings response $json";
    my $JSON = JSON->new->utf8(0)->allow_nonref;
    my $parsed = eval {$JSON->decode ($json)};
    if($@){
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting settings: $@";
    } else {
      my %readings = ();
      HomeConnect_parseSettingsToHash(\%readings,$parsed);

      readingsBeginUpdate($hash);
      for my $get (keys %readings) {
        readingsBulkUpdate($hash, $get, $readings{$get});
      }
      readingsEndUpdate($hash, 1);
    };
  }
}

#####################################
sub HomeConnect_GetPrograms
{
  my ($hash) = @_;

  my $operationState = ReadingsVal($hash->{NAME},"BSH.Common.Status.OperationState","");
  my $activeProgram = ReadingsVal($hash->{NAME},"BSH.Common.Root.ActiveProgram",undef);

  if ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
      $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
      $operationState eq "BSH.Common.EnumType.OperationState.Run") {
    if (defined $activeProgram) {
      #### Currently we dont get a list of programs if a program is active, so we just use the active program name
      my $prefix = HomeConnect_checkPrefix(undef, $activeProgram);
      my $prefixLen = length $prefix;
      $hash->{commandPrefix} = $prefix;
      $hash->{programs} = substr($activeProgram, $prefixLen);
    }
    return;
  }

  #### Request available programs
  my $data = {
    callback => \&HomeConnect_ResponseGetPrograms,
    uri => "/api/homeappliances/$hash->{haId}/programs/available"
  };
  HomeConnectConnection_request($hash,$data);
}

#####################################
sub HomeConnect_ResponseGetPrograms
{
  my ($hash, $json) = @_;

  if (defined $json) {
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: get programs response $json";

    my $JSON = JSON->new->utf8(0)->allow_nonref;
    my $parsed = eval {$JSON->decode ($json)};
    if($@){
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting programs: $@";
    } else {
      my %readings = ();
      my @pgms = ();
      my $prefix;
      for (my $i = 0; 1; $i++) {
        my $programline = $parsed->{data}->{programs}[$i];
        if (!defined $programline) { last };
        push (@pgms, $programline->{key});
        $prefix = HomeConnect_checkPrefix($prefix, $programline->{key});
      }
      #### command beautyfication: remove a common prefix
      my $prefixLen = length $prefix;
      my $programs = ""; 
      foreach my $program (@pgms) {
        if ($programs ne "") {
          $programs .= ",";
        }
        $programs .= substr($program, $prefixLen);
      }
      $hash->{commandPrefix} = $prefix;
      $hash->{programs} = $programs;
    };
  }
}

#####################################
sub HomeConnect_checkPrefix
{
  my ($prefix, $value) = @_;

  if (!defined $prefix) {
    $value =~ /(.*)\..*$/;
    return $1.".";
  } else {
    for (my $i=0; $i < length $value; $i++) {
      if (substr($prefix, $i, 1) ne substr($value, $i, 1)) {
        return substr($prefix, 0, $i);
      }
    }
    return $value;
  }
}

#####################################
sub HomeConnect_parseOptionsToHash
{
  my ($hash, $parsed) = @_;
  my %options = ();

  for (my $i = 0; 1; $i++) {
    my $optionsline = $parsed->{data}->{options}[$i];
    if (!defined $optionsline) { last };
    my $key = $optionsline->{key};
#    $key =~ tr/\\./_/;
    $options{ $key } = "$optionsline->{value} $optionsline->{unit}";
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: $key = $optionsline->{value} $optionsline->{unit}";
  }
  return \%options;
}

#####################################
sub HomeConnect_parseOptionsToHash2
{
  my ($hash,$parsed) = @_;

  for (my $i = 0; 1; $i++) {
    my $optionsline = $parsed->{data}->{options}[$i];
    if (!defined $optionsline) { last };
    my $key = $optionsline->{key};
#    $key =~ tr/\\./_/;
    $hash->{$key} = "$optionsline->{value}" if (defined $optionsline->{value});
    $hash->{$key} .= " $optionsline->{unit}" if (defined $optionsline->{unit});
#    Log3 $hash->{NAME}, 4, "$hash->{NAME}: $key = $optionsline->{value} $optionsline->{unit}";
  }
}

#####################################
sub HomeConnect_parseSettingsToHash
{
  my ($hash,$parsed) = @_;

  for (my $i = 0; 1; $i++) {
    my $optionsline = $parsed->{data}->{settings}[$i];
    if (!defined $optionsline) { last };
    my $key = $optionsline->{key};
    $hash->{$key} = "$optionsline->{value}" if (defined $optionsline->{value});
    $hash->{$key} .= " $optionsline->{unit}" if (defined $optionsline->{unit});
  }
}

#####################################
sub HomeConnect_ShortenKey
{
  my ($key) = @_;
  my ($b,$c) = $a =~ m|^(.*[\.])([^\.]+?)$|;
  return $c;
}

#####################################
sub HomeConnect_UpdateStatus
{
  my ($hash) = @_;
  
  #### Get status variables
  my $data = {
    callback => \&HomeConnect_ResponseUpdateStatus,
    uri => "/api/homeappliances/$hash->{haId}/status"
  };
  my $json = HomeConnectConnection_request($hash,$data);
}

#####################################
sub HomeConnect_ResponseUpdateStatus
{
  my ($hash, $json) = @_;
  if (!defined $json) {
    # no status available
    return;
  }
  
  Log3 $hash->{NAME}, 4, "$hash->{NAME}: status response $json";

  my $JSON = JSON->new->utf8(0)->allow_nonref;
  my $parsed = eval{$JSON->decode ($json)};
  if($@){
    Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting status: $@";
    return;
  }

  my %readings = ();
  for (my $i = 0; 1; $i++) {
    my $statusline = $parsed->{data}->{status}[$i];
    if (!defined $statusline) { last };
    $readings{$statusline->{key}} = $statusline->{value};
    $readings{$statusline->{key}}.=" ".$statusline->{unit} if defined $statusline->{unit};
  }

  if ($parsed->{error}) {
    if (defined $parsed->{error}->{description}) {
      if ($parsed->{error}->{description} =~ m/.*offline.*/) {
        $readings{"state"} = "Offline" if ($hash->{STATE} ne "Offline");
        $hash->{STATE} = "Offline";
      }
    }
  } 

  my $operationState = $readings{"BSH.Common.Status.OperationState"};
  my $pgmRunning = defined $operationState &&
       ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
        $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
        $operationState eq "BSH.Common.EnumType.OperationState.Run"
       );

  #### Update Readings
  readingsBeginUpdate($hash);
  for my $get (keys %readings) {
    readingsBulkUpdate($hash, $get, $readings{$get});
  }
  readingsEndUpdate($hash, 1);

  if ($pgmRunning) {
    #### Check for a running program
    HomeConnect_CheckProgram($hash);
  }
}

#####################################
sub HomeConnect_CheckProgram
{
  my ($hash) = @_;
  
  #### Get status variables
  my $data = {
    callback => \&HomeConnect_ResponseCheckProgram,
    uri => "/api/homeappliances/$hash->{haId}/programs/active"
  };
  HomeConnectConnection_request($hash,$data);
}

#####################################
sub HomeConnect_ResponseCheckProgram
{
  my ($hash, $json) = @_;
  my %readings = ();

  if (!defined $json) {
    # no program running
    $readings{state} = "Idle";
    $readings{"BSH.Common.Root.ActiveProgram"} = "None";
    $readings{"BSH.Common.Option.RemainingProgramTime"} = "0 seconds";
    $readings{"BSH.Common.Option.ProgramProgress"} = "0 %";
  } else {
    Log3 $hash->{NAME}, 4, "$hash->{NAME}: program response $json";

    my $JSON = JSON->new->utf8(0)->allow_nonref;
    my $parsed = eval {$JSON->decode ($json)};
    if($@){
      Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error requesting status: $@";
    } else {
      $readings{"BSH.Common.Root.ActiveProgram"} = $parsed->{data}->{key};
      HomeConnect_parseOptionsToHash2(\%readings,$parsed);
  
      $readings{state} = "Program active";
  
      $readings{state} .= " (".$readings{"BSH.Common.Option.ProgramProgress"} .")" if defined $readings{"BSH.Common.Option.ProgramProgress"};
    };
  }

  #### Update Readings
  readingsBeginUpdate($hash);
  for my $get (keys %readings) {
    readingsBulkUpdate($hash, $get, $readings{$get});
  }
  readingsEndUpdate($hash, 1);
}

#####################################
sub HomeConnect_ConnectEventChannel
{
  my ($hash) = @_;
  my $haId = $hash->{haId};
  my $api_uri = $defs{$hash->{hcconn}}->{api_uri};

  my $param = {
    url => "$api_uri/api/homeappliances/$haId/events",
    hash       => $hash,
    timeout    => 10,
    noshutdown => 1,
    noConn2    => 1,
    httpversion=> "1.1",
    keepalive  => 1,
    callback   => \&HomeConnect_HttpConnected
  };

  Log3 $hash->{NAME}, 5, "$hash->{NAME}: connecting to event channel";

  HttpUtils_NonblockingGet($param);

}

#####################################
sub HomeConnect_HttpConnected
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  # this is a callback used by HttpUtils_NonblockingGet
  # it will be called after the http socket connection has been opened
  # and handles the http protocol part.

  # make sure we're really connected
  if (!defined $param->{conn}) {
    HomeConnect_CloseEventChannel($hash);
    return;
  }

  my ($gterror, $token) = getKeyValue($hash->{hcconn}."_accessToken");
  my $method = $param->{method};
  $method = ($data ? "POST" : "GET") if( !$method );

  my $httpVersion = $param->{httpversion} ? $param->{httpversion} : "1.0";
  my $hdr = "$method $param->{path} HTTP/$httpVersion\r\n";
  $hdr .= "Host: $param->{host}\r\n";
  $hdr .= "User-Agent: fhem\r\n" if(!$param->{header} || $param->{header} !~ "User-Agent:");
  $hdr .= "Accept: text/event-stream\r\n";
  $hdr .= "Accept-Encoding: gzip,deflate\r\n" if($param->{compress});
  $hdr .= "Connection: keep-alive\r\n" if($param->{keepalive});
  $hdr .= "Connection: Close\r\n" if($httpVersion ne "1.0" && !$param->{keepalive});
  $hdr .= "Authorization: Bearer $token\r\n";
  if(defined($data)) {
    $hdr .= "Content-Length: ".length($data)."\r\n";
    $hdr .= "Content-Type: application/x-www-form-urlencoded\r\n" if ($hdr !~ "Content-Type:");
  }
  $hdr .= "\r\n";

  Log3 $hash->{NAME}, 5, "$hash->{NAME}: sending headers to event channel: $hdr";

  syswrite $param->{conn}, $hdr;
  $hash->{conn} = $param->{conn};
  $hash->{eventChannelTimeout} = time();

  Log3 $hash->{NAME}, 5, "$hash->{NAME}: connected to event channel";

  # the server connection is left open to receive new events
}

#####################################
sub HomeConnect_CloseEventChannel($)
{
  my ( $hash ) = @_;

  if (defined $hash->{conn}) {
    $hash->{conn}->close();
    delete($hash->{conn});
    Log3 $hash->{NAME}, 5, "$hash->{NAME}: disconnected from event channel";
  }
}

#####################################
sub HomeConnect_ReadEventChannel($)
{
	my ($hash) = @_;
	my $inputbuf;
	my $JSON = JSON->new->utf8(0)->allow_nonref;

	if (defined $hash->{conn}) {
		my ($rout, $rin) = ('', '');
		vec($rin, $hash->{conn}->fileno(), 1) = 1;

		# check for timeout
		if (defined $hash->{eventChannelTimeout} &&
			(time() - $hash->{eventChannelTimeout}) > 140) {
			Log3 $hash->{NAME}, 2, "$hash->{NAME}: event channel timeout, two keep alive messages missing";
			HomeConnect_CloseEventChannel($hash);
			return undef;
		}

		my $count = 0;

		# read data
		while($hash->{conn}->fileno()) {
			# loop monitoring
			$count  = $count + 1;
			if ($count > 100){
				Log3 $hash->{NAME}, 2, "$hash->{NAME}: event channel fatal error: infinite loop";
				last;
			}
			# check channel data availability
			my $tmp = $hash->{conn}->fileno();
			my $nfound = select($rout=$rin, undef, undef, 0);
			Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel searching for data, fileno:\"$tmp\", nfound:\"$nfound\", loopCounter:\"$count\"";

			if($nfound < 0) {
				Log3 $hash->{NAME}, 2, "$hash->{NAME}: event channel timeout/error: $!";
				HomeConnect_CloseEventChannel($hash);
				return undef;
			}
			if($nfound == 0) {
				last;
			}

			my $len = sysread($hash->{conn},$inputbuf,32768);
			Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel len:\"$len\", received:\"$inputbuf\"";

			# check if something was actually read
			if (defined($len) && $len > 0 && defined($inputbuf) && length($inputbuf) > 0) {

				# process data
				Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel received $inputbuf";

				# reset timeout
				$hash->{eventChannelTimeout} = time();

				readingsBeginUpdate($hash);

				# split data into lines,
				for (split /^/, $inputbuf) {
					# check for http result line
          if (length($_) == 0) {
            next 
          }
					if (index($_,"HTTP/1.1") == 0) {
						if (substr($_,9,3) ne "200") {
							Log3 $hash->{NAME}, 2, "$hash->{NAME}: event channel received an http error: $_";
							HomeConnect_CloseEventChannel($hash);
							return undef;
						} else {
							# successful connection, reset counter
							$hash->{retrycounter} = 0;
						}
					} elsif (index($_,"data:") == 0) { # extract data json elements
						if (length ($_) < 10) { next };
						my $json = substr($_,5);
						Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel data: $json";

						my $parsed = eval {$JSON->decode ($json)};
						if($@){
							Log3 $hash->{NAME}, 2, "$hash->{NAME}: JSON error reading from event channel";
						} else {
							# update readings from json elements
							my %readings = ();
							for (my $i = 0; 1; $i++) {
								my $item = $parsed->{items}[$i];
								if (!defined $item) { last };
								my $key = $item->{key};
								$readings{$key}=(defined $item->{value})?$item->{value}:"-";
								$readings{$key}.=" ".$item->{unit} if defined $item->{unit};

								if ($key eq "BSH.Common.Root.SelectedProgram" && 
									defined($hash->{commandPrefix}) && length($readings{$key}) > length($hash->{commandPrefix}) ) {
									my $prefixLen = length $hash->{commandPrefix};
									$readings{$key} = substr($readings{$key}, $prefixLen);
								}

								readingsBulkUpdate($hash, $key, $readings{$key});
								Log3 $hash->{NAME}, 4, "$hash->{NAME}: $key = $readings{$key}";
							}
						}
						# define new device state
						my $state;
						my $operationState = ReadingsVal($hash->{NAME},"BSH.Common.Status.OperationState","");
						my $program = ReadingsVal($hash->{NAME},"BSH.Common.Root.ActiveProgram","");
						if (defined($program) && defined($hash->{commandPrefix}) && length($program) > length($hash->{commandPrefix}) ) {
							my $prefixLen = length $hash->{commandPrefix};
							$program = substr($program, $prefixLen);
						}
						if ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
							$operationState eq "BSH.Common.EnumType.OperationState.Run") {

							$state = "Program $program active";
							my $pct = ReadingsVal($hash->{NAME},"BSH.Common.Option.ProgramProgress",undef);
							$state .= " ($pct)" if (defined $pct);
						} elsif ($operationState eq "BSH.Common.EnumType.OperationState.DelayedStart") {
							$state = "Delayed start of program $program";
						} else {
							$state = "Idle";
						}
						readingsBulkUpdate($hash, "state", $state) if ($hash->{STATE} ne $state);
					} elsif (index($_,"event:DISCONNECTED") == 0) { # disconnected event Morluktom 10.05.2020
						my $state = "Offline";
						readingsBulkUpdate($hash, "state", $state) if ($hash->{STATE} ne $state);
					} elsif (index($_,"event:CONNECTED") == 0) { # connected event Morluktom 10.05.2020
						HomeConnect_UpdateStatus($hash);
					} else {
            #Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel unknown: $_";
          }
				}
				readingsEndUpdate($hash, 1);
			} else {
				Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel read failed, len:\"$len\", received:\"$inputbuf\"";
				HomeConnect_CloseEventChannel($hash);
				return undef;
			}
		} 
		Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel received no more data";
	} else {
		Log3 $hash->{NAME}, 5, "$hash->{NAME}: event channel is not connected";
	}
}



1;

=pod
=begin html

<a name="HomeConnect"></a>
<h3>HomeConnect</h3>
<ul>
  <a name="HomeConnect_define"></a>
  <h4>Define</h4>
  <ul>
    <code>define &lt;name&gt; HomeConnect &lt;connection&gt; &lt;haId&gt;</code>
    <br/>
    <br/>
    Defines a single Home Connect household appliance. See <a href="http://www.home-connect.com/">Home Connect</a>.<br><br>
    Example:

    <code>define Dishwasher HomeConnect hcconn SIEMENS-HCS02DWH1-83D908F0471F71</code><br>

    <br/>
	Typically the Home Connect devices are created automatically by the scanDevices action in HomeConnectConnection.
    <br/>
  </ul>

  <a name="HomeConnect_set"></a>
  <b>Set</b>
  <ul>
    <li>BSH.Common.Root.SelectedProgram<br>
      Select a program on the appliance. A program name must be given as first parameter. 
      This prepares the appliance for a program start and presets the program options with sensible defaults.
    <li>startProgram<br>
      Start a program on the appliance. The program currently selected on the appliance will be started by default.
      A program name can be given as first parameter. The program will be started with specific options.
      </li>
    <li>stopProgram<br>
      Stop the running program on the appliance.
      </li>
    <li>requestProgramOptions<br>
      Read options for a specific appliance program and add them to Readings for later editing.
      </li>
    <li>requestSettings<br>
      Read all settings available for the appliance and add them to Readings for later editing.
      </li>
  </ul>
  <br>

  <a name="HomeConnect_Attr"></a>
  <h4>Attributes</h4>
  <ul>
    <li><a name="updateTimer"><code>attr &lt;name&gt; updateTimer &lt;Integer&gt;</code></a>
                <br />Interval for update checks, default is 10 seconds</li>
  </ul>
</ul>

=end html
=cut
