#include<sourcemod>
#include<cstrike>
#include<sdktools>

public Plugin:myinfo =
{
    name = "Live on Three Match Plugin",
    author = "execut1ve",
    description = "CS:GO Match Plugin (Tournament Support)",
    version = "1.5.6",
    url = "https://lo3.jp"
};

new Handle:cvar_sv_coaching_enabled;
new Handle:cvar_lo3_kniferound_enabled;
new Handle:cvar_lo3_tournament_mode;
new Handle:cvar_lo3_match_config;
new Handle:cvar_lo3_record_start_map;
new Handle:cvar_lo3_tv_force_disable;
new Handle:cvar_tv_enable;
new Handle:cvar_tv_autorecord;
new Handle:message_timer;
new String:LO3_MATCH_CONFIG_DEFAULT[64];

new nowphase = 0; // 0=warmup, 1=matchlive, 2=kniferound, 3=afterkniferound
new bool:nowfreezetime = false;
new bool:ready_t = false;
new bool:ready_ct = false;

new bool:paused = false;
new bool:unpaused_t = false;
new bool:unpaused_ct = false;
new bool:timeouted = false;

new knife_winteam = 0;

new bool:matchstop_t = false;
new bool:matchstop_ct = false;

new bool:message_live_end = false;
new bool:message_knifelive_end = false;

new bool:demorecord_ready = false;

new bool:clinchvote_t = false;
new bool:clinchvote_ct = false;

Menu g_MapMenu = null;


public OnPluginStart() {
  RegConsoleCmd("say", Command_Say);
  RegConsoleCmd("say_team", Command_Say);
  RegConsoleCmd("menu_changemap", Command_ChangeMap);
  cvar_sv_coaching_enabled = FindConVar("sv_coaching_enabled");
  cvar_lo3_kniferound_enabled = CreateConVar("lo3_kniferound_enabled", "0", "If non-zero, enable kniferound" );
  cvar_lo3_tournament_mode = CreateConVar("lo3_tournament_mode", "0", "If non-zero, disabled swap and scramble" );
  cvar_lo3_match_config = CreateConVar("lo3_match_config", "lo3_tournament.cfg", "execute configs on live" );
  cvar_lo3_record_start_map = CreateConVar("lo3_record_start_map", "0", "If non-zero, GOTV demo start recording when map started");
  cvar_lo3_tv_force_disable = CreateConVar("lo3_record_disable", "0", "If non-zero, disable GOTV")
  cvar_tv_enable = FindConVar("tv_enable");
  cvar_tv_autorecord = FindConVar("tv_autorecord");
  HookConVarChange(cvar_tv_enable, Force_TV_Enable);
  HookConVarChange(cvar_tv_autorecord, Force_AutoRecord_Disable);
  HookEvent("round_end", ev_round_end);
  HookEvent("round_start", ev_round_start);
  HookEvent("round_freeze_end", ev_round_freeze_end);
  HookEvent("cs_match_end_restart", ev_cs_match_end_restart);
  HookEvent("switch_team", ev_switch_team);
}

public Force_TV_Enable(Handle:cvar, const String:oldVal[], const String:newVal[]) {
    if ( GetConVarInt(cvar_lo3_tv_force_disable) == 0 ) {
      SetConVarInt(cvar, 1);
    }
    else {
      SetConVarInt(cvar, 0);
    }
}

public Force_AutoRecord_Disable(Handle:cvar, const String:oldVal[], const String:newVal[]) {
    SetConVarInt(cvar, 0);
}

public OnMapStart() {
  reset_stat();
  ServerCommand("mp_death_drop_gun 0");
  ServerCommand("tv_autorecord 0");
  g_MapMenu = BuildMapMenu();
  nowphase = 0;
  if ( GetConVarInt(cvar_lo3_record_start_map) == 1 ) {
    CreateTimer(5.0, StartRecord);
  }
}

public OnMapEnd() {
  if (g_MapMenu != null) {
    delete(g_MapMenu);
    g_MapMenu = null;
  }
  nowphase = 0;
}

Menu BuildMapMenu() {
  File file = OpenFile("maplist.txt", "rt");
  if (file == null) {
    return null;
  }

  Menu menu = new Menu(Menu_ChangeMap);
  char mapname[255];
  while (!file.EndOfFile() && file.ReadLine(mapname, sizeof(mapname))) {
    if (mapname[0] == ';' || !IsCharAlpha(mapname[0])) {
      continue;
    }

    /* Cut off the name at any whitespace */
    int len = strlen(mapname);
    for (int i=0; i<len; i++) {
      if (IsCharSpace(mapname[i])) {
        mapname[i] = '\0';
        break;
      }
    }
    /* Check if the map is valid */
    if (!IsMapValid(mapname)) {
      continue;
    }
    /* Add it to the menu */
    menu.AddItem(mapname, mapname);
  }
  /* Make sure we close the file! */
  file.Close();

  /* Finally, set the title */
  menu.SetTitle("Please select a map:");

  return menu;
}

public ev_round_end(Handle:event, const String:name[], bool:dontBroadcast) {
  nowfreezetime = true;
  timeouted = false;
  matchstop_t = false;
  matchstop_ct = false;

  if ( nowphase == 2 ){
    int winner = GetEventInt(event, "winner"); //2=T,3=CT

    if ( winner == 2 ){
      PrintToChatAll("[\x04LO3\x01] Terrorsit がナイフラウンドに勝利しました");
      knife_winteam = 1;
    }
    if ( winner == 3 ){
      PrintToChatAll("[\x04LO3\x01] CT がナイフラウンドに勝利しました");
      knife_winteam = 2;
    }

    nowphase = 3;
    CreateTimer(3.0, knife_reset);
  }
}

public ev_round_start(Handle:event, const String:name[], bool:dontBroadcast) {
  if ( GameRules_GetProp("m_bWarmupPeriod") == 1 ) {
    ServerCommand("mp_t_default_primary weapon_ak47");
    ServerCommand("mp_ct_default_primary weapon_m4a1");
    ServerCommand("mp_free_armor 2");
    ServerCommand("mp_death_drop_gun 0");

    if ( demorecord_ready ) {
      CreateTimer(1.0, StartRecord);
      demorecord_ready = false;
    }
    if ( nowphase == 0 ) {
      if ( message_timer == null ) {
        message_timer = CreateTimer(0.5, message_ready, _, TIMER_REPEAT);
      }
      return;
    }
    else if ( nowphase == 3 ) {
      if ( message_timer == null ) {
        message_timer = CreateTimer(0.5, message_knifechoose, _, TIMER_REPEAT);
      }
      return;
    }
    else if ( nowphase == 4 ){
      CreateTimer(1.0, knife_switch_warmupend);
    }
  }
  else {
    if ( nowphase == 1 && !message_live_end ) {
      CreateTimer(1.0, message_live);
    }
    else if ( nowphase == 2 && !message_knifelive_end ) {
      CreateTimer(1.0, message_knifelive);
    }
  }
}

public ev_round_freeze_end(Handle:event, const String:name[], bool:dontBroadcast) {
    nowfreezetime = false;
    timeouted = false;
}

public ev_cs_match_end_restart(Handle:event, const String:name[], bool:dontBroadcast) {
  if ( GetConVarInt(cvar_lo3_record_start_map) == 0 ) {
    ServerCommand("tv_stoprecord");
  }
  nowphase = 0;
  reset_stat();
  ServerCommand("mp_warmup_start");
}

public ev_switch_team(Handle:event, const String:name[], bool:dontBroadcast) {
  if ( GameRules_GetProp("m_bWarmupPeriod") == 1 ) {
    CreateTimer(1.0, kickbot)
  }
}

public int Menu_ChangeMap(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_Select) {
    char info[32];

    /* Get item info */
    bool found = menu.GetItem(param2, info, sizeof(info));

    /* Tell the client */
    PrintToConsole(param1, "You selected item: %d (found? %d info: %s)", param2, found, info);

    /* Change the map */
    ServerCommand("changelevel %s", info);
  }
}

public Action Command_ChangeMap(int client, int args) {
  if (g_MapMenu == null) {
    PrintToConsole(client, "The maplist.txt file was not found!");
    return Plugin_Handled;
  }

  g_MapMenu.Display(client, MENU_TIME_FOREVER);
  return Plugin_Handled;
}

public Action:Command_Say(client, args) {
  new String:text[128];
  GetCmdArg(1, text, sizeof(text));

  if (StrEqual(text, "!timeout")) {
    timeout(client);
  }
  else if (StrEqual(text, "!pause")) {
    pause(client);
  }
  else if (StrEqual(text, "!unpause")) {
    unpause(client);
  }
  else if (StrEqual(text, "!coach")) {
    coach(client);
  }
  else if (StrEqual(text, "!coach t")) {
    coacht(client);
  }
  else if (StrEqual(text, "!coach ct")) {
    coachct(client);
  }
  else if (StrEqual(text, "!ready")) {
    ready(client);
  }
  else if (StrEqual(text, "!r")) {
    ready(client);
  }
  else if (StrEqual(text, "!unready")) {
    unready(client);
  }
  else if (StrEqual(text, "!stop")) {
    matchstop(client);
  }
  else if (StrEqual(text, "!restart")) {
    matchstop(client);
  }
  else if (StrEqual(text, "!switch")) {
    knife_switch(client);
  }
  else if (StrEqual(text, "!stay")) {
    knife_stay(client);
  }
  else if (StrEqual(text, "!help")) {
    PrintToChatAll("[\x04LO3\x01] \x05!ready\x01(\x05!r\x01),\05!unready\x01 : 試合準備・解除");
    PrintToChatAll("[\x04LO3\x01] \05!coach [t,ct(any)]\x01 : コーチモード");
    PrintToChatAll("[\x04LO3\x01] \05!pause\x01,\05!unpause\x01 : ポーズ・解除");
    PrintToChatAll("[\x04LO3\x01] \05!timeout\x01 : タイムアウト(30秒/4回まで)");
    PrintToChatAll("[\x04LO3\x01] \05!stop\x01(\05!restart\x01) : 試合中断");
    PrintToChatAll("[\x04LO3\x01] \05!map\x01 : マップ変更");
  }
  else if (StrEqual(text, "!scramble")) {
    scramble(client);
  }
  else if (StrEqual(text,"!swap")) {
    swap(client);
  }
  else if (StrEqual(text,"!resetstat")) {
    if ( nowphase == 0 ) {
      reset_stat();
      PrintToChatAll("[\x04LO3\x01] \x02RESET ALL STATUS");
    }
  }
  else if (StrEqual(text,"!map")) {
    mapchange(client);
  }
  else if (StrEqual(text,"!30r")) {
    clinchvote(client);
  }
  else if (StrEqual(text,"!16r")) {
    clinchunvote(client);
  }
}

public Action:kickbot(Handle:timer) {
  ServerCommand("bot_kick");
}

public Action:knife_reset(Handle:timer) {
  reset_stat();
  ServerCommand("mp_warmup_start");
}

public Action:message_ready(Handle:timer) {
  for(int i = 1;i <= MaxClients; i++) {
    if ( !ready_t && !ready_ct )  {
      if ( GetConVarInt(cvar_lo3_tournament_mode) == 0 ) {
        if ( !clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\n<font color='#00ff00'>!30r</font> :");
        }
        else if ( clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\n<font color='#00ff00'>!30r</font> : Terrorist");
        }
        else if ( !clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\n<font color='#00ff00'>!30r</font> : CT");
        }
        else if ( clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\n!30r : Terrorist / CT\n<font color='#00ff00'>!16r</font> でキャンセル");
        }
      }
      else {
        if ( GetConVarInt(cvar_lo3_kniferound_enabled) == 0 ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\nKnifeRound : なし");
        }
        else {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> :\nKnifeRound : あり");
        }
      }
    }
    else if ( ready_t && !ready_ct ) {
      if ( GetConVarInt(cvar_lo3_tournament_mode) == 0 ) {
        if ( !clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\n<font color='#00ff00'>!30r</font> :");
        }
        else if ( clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\n<font color='#00ff00'>!30r</font> : Terrorist");
        }
        else if ( !clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\n<font color='#00ff00'>!30r</font> : CT");
        }
        else if ( clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\n!30r : Terrorist / CT\n<font color='#00ff00'>!16r</font> でキャンセル");
        }
      }
      else {
        if ( GetConVarInt(cvar_lo3_kniferound_enabled) == 0 ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\nKnifeRound : なし");
        }
        else {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : Terrorist\nKnifeRound : あり");
        }
      }
      }
    else if ( !ready_t && ready_ct ) {
      if ( GetConVarInt(cvar_lo3_tournament_mode) == 0 ) {
        if ( !clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\n<font color='#00ff00'>!30r</font> :");
        }
        else if ( clinchvote_t && !clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\n<font color='#00ff00'>!30r</font> : Terrorist");
        }
        else if ( !clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\n<font color='#00ff00'>!30r</font> : CT");
        }
        else if ( clinchvote_t && clinchvote_ct ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\n!30r : Terrorist / CT\n<font color='#00ff00'>!16r</font> でキャンセル");
        }
      }
      else {
        if ( GetConVarInt(cvar_lo3_kniferound_enabled) == 0 ) {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\nKnifeRound : なし");
        }
        else {
          PrintHintTextToAll("<font color='#00ff00'>!ready</font> : CT\nKnifeRound : あり");
        }
      }
    }
  }
  return Plugin_Continue;
}

public Action:message_pause(Handle:timer) {
  for(int i = 1;i <= MaxClients; i++) {
    if ( !unpaused_t && !unpaused_ct ) {
      PrintHintTextToAll("<font color='#00ff00'>!unpause</font> :");
    }
    else if ( unpaused_t && !unpaused_ct )  {
      PrintHintTextToAll("<font color='#00ff00'>!unpause</font> : Terrorist");
    }
    else if ( !unpaused_t && unpaused_ct ) {
      PrintHintTextToAll("<font color='#00ff00'>!unpause</font> : CT");
    }
  }
  return Plugin_Continue;
}

public Action:message_live(Handle:timer) {
  for(new i = 0; i <= 6; i++) {
    PrintToChatAll("[\x04LO3\x01] -=!Live!=-");
  }
  PrintToChatAll("[\x04LO3\x01] \06Good Luck and Have Fun!");
  message_live_end = true;
  clinchvote_t = false;
  clinchvote_ct = false;
}

public Action:message_knifelive(Handle:timer) {
  for(new i = 0; i <= 6; i++) {
    PrintToChatAll("[\x04LO3\x01] -=!Knife!=-");
  }
  message_knifelive_end = true;
}

public Action:message_knifechoose(Handle:timer) {
  for(int i = 1;i <= MaxClients; i++) {
    if ( knife_winteam == 1 ) {
      PrintHintText(i,"KnifeRound Winner : Terrorist\nCommand : <font color='#00ff00'>!switch</font> / <font color='#00ff00'>!stay</font>");
    }
    else if ( knife_winteam == 2 )  {
      PrintHintText(i,"KnifeRound Winner : CT\nCommand : <font color='#00ff00'>!switch</font> / <font color='#00ff00'>!stay</font>");
    }
  }
  return Plugin_Continue;
}

public Action:knife_switch_warmupend(Handle:timer) {
  reset_stat();
  ServerCommand("mp_warmuptime 10");
  ServerCommand("mp_warmup_pausetimer 0");
  nowphase = 1;
}

public Action:StartRecord(Handle:timer,any:client) {
  if ( GetConVarInt(cvar_tv_enable) == 1 ) {
      new String:year[16],
          String:month[16],
          String:date[16],
          String:hour[16],
          String:minute[16],
          String:map[128];

      //tv_autorecord format
      FormatTime(year, sizeof(year), "%Y");
      FormatTime(month, sizeof(month), "%m");
      FormatTime(date, sizeof(date), "%d");
      FormatTime(hour, sizeof(hour), "%H");
      FormatTime(minute, sizeof(minute), "%M");
      GetCurrentMap(map,sizeof(map));

      //for workshop maps
      ReplaceString(map,sizeof(map),"/","_");//replace map name. "/"  to "_"

      //start record
      ServerCommand("tv_record auto-%s%s%s-%s%s-%s",year,month,date,hour,minute,map);
      PrintToServer("demo record has started.");
  }
}

public reset_stat() {
  ServerCommand("exec lo3_matchplugin.cfg")
  GetConVarString(cvar_lo3_match_config, LO3_MATCH_CONFIG_DEFAULT, sizeof(LO3_MATCH_CONFIG_DEFAULT));
  new String:cfg[64];
  GetConVarString(cvar_lo3_match_config, cfg, sizeof(cfg));
  ServerCommand("exec %s", cfg);
  ServerCommand("mp_team_timeout_max 4");
  ServerCommand("mp_team_timeout_time 30");
  ServerCommand("mp_t_default_primary \"\"");
  ServerCommand("mp_ct_default_primary \"\"");
  ServerCommand("mp_t_default_secondary weapon_glock");
  ServerCommand("mp_ct_default_secondary weapon_hkp2000");
  ServerCommand("mp_free_armor 0");
  ServerCommand("mp_startmoney 800");
  ServerCommand("mp_warmup_pausetimer 1");
  ServerCommand("mp_warmuptime_all_players_connected 0");
  nowfreezetime = false;
  ready_t = false;
  ready_ct = false;
  message_live_end = false;
  paused = false;
  unpaused_t = false;
  unpaused_ct = false;
  timeouted = false;
  message_knifelive_end = false;
  matchstop_t = false;
  matchstop_ct = false;
  if ( clinchvote_t && clinchvote_ct ) {
    ServerCommand("mp_match_can_clinch 0");
  }
}

public ready(client) {
  if ( nowphase == 0 )  {
    new team = GetClientTeam(client);

    if ( team == CS_TEAM_T ) {
      ready_t = true;
    }
    else if ( team == CS_TEAM_CT ) {
      ready_ct = true;
    }

    if ( ready_t && ready_ct )  {
      if ( GetConVarInt(cvar_lo3_record_start_map) == 0 ) {
        demorecord_ready = true;
      }
      ServerCommand("mp_warmup_start");
      if ( GetConVarInt(cvar_lo3_kniferound_enabled) == 1 ) {
        PrintToChatAll("[\x04LO3\x01] 両チームの準備が完了しました");
        PrintToChatAll("[\x04LO3\x01] \x0410秒後にナイフラウンドが開始されます");
        reset_stat();
        ServerCommand("mp_t_default_secondary \"\"");
        ServerCommand("mp_ct_default_secondary \"\"");
        ServerCommand("mp_startmoney 0");
        ServerCommand("mp_free_armor 1");
        nowphase = 2;
      }
      else {
        PrintToChatAll("[\x04LO3\x01] 両チームの準備が完了しました");
        PrintToChatAll("[\x04LO3\x01] \x0410秒後に試合が開始されます");
        reset_stat();
        nowphase = 1;
      }
      ServerCommand("mp_warmuptime 10");
      ServerCommand("mp_warmup_pausetimer 0");
      ready_t = false;
      ready_ct = false;
      KillTimer(message_timer);
      message_timer = null;
    }
    else if ( ready_t && !ready_ct ) {
      PrintToChatAll("[\x04LO3\x01] Terrorist の準備が完了しました");
    }
    else if ( !ready_t && ready_ct ) {
      PrintToChatAll("[\x04LO3\x01] CT の準備が完了しました");
    }
  }
}

public unready(client) {
  if ( nowphase == 0 ) {
    new team = GetClientTeam(client);

    if (team == CS_TEAM_T) {
      PrintToChatAll("[\x04LO3\x01] Terrorsit の準備完了状態が解除されました");
      ready_t = false;
    }
    else if (team == CS_TEAM_CT) {
      PrintToChatAll("[\x04LO3\x01] CT の準備完了状態が解除されました");
      ready_ct = false;
    }
  }
}

public pause(client) {
  if ( nowfreezetime && nowphase == 1 ) {
    paused = true;
    new team = GetClientTeam(client);

    if (team == CS_TEAM_T) {
      PrintToChatAll("[\x04LO3\x01] Terrorist がポーズを宣言しました");
    }
    else if (team == CS_TEAM_CT) {
      PrintToChatAll("[\x04LO3\x01] CT がポーズを宣言しました");
    }
    ServerCommand("mp_pause_match");
    if ( message_timer == null ) {
      message_timer = CreateTimer(0.5, message_pause, _, TIMER_REPEAT);
    }
  }
  else if ( paused ) {
    PrintToChatAll("[\x04LO3\x01] 既にポーズ状態です");
  }
}

public unpause(client) {
  if ( paused )  {
    new team = GetClientTeam(client);

    if (team == CS_TEAM_T) {
      unpaused_t = true;
    }
    else if (team == CS_TEAM_CT) {
      unpaused_ct = true;
    }

    if ( unpaused_t && unpaused_ct )  {
      ServerCommand("mp_unpause_match");
      PrintToChatAll("[\x04LO3\x01] ポーズが解除されました");
      KillTimer(message_timer);
      message_timer = null;
      paused = false;
      unpaused_t = false;
      unpaused_ct = false;
    }
    else if ( unpaused_t && !unpaused_ct ) {
      PrintToChatAll("[\x04LO3\x01] Terrorsit がポーズを解除する準備を完了しました");
    }
    else if ( !unpaused_t && unpaused_ct ) {
      PrintToChatAll("[\x04LO3\x01] CT がポーズを解除する準備を完了しました");
    }
  }
}

public timeout(client) {
  if ( nowfreezetime && nowphase == 1 && !timeouted ) {
    if ( paused ) {
      PrintToChatAll("[\x04LO3\x01] タイムアウトはポーズ中に実行できません")
    }
    else if ( timeouted ) {
      PrintToChatAll("[\x04LO3\x01] 既にタイムアウト状態です")
    }
    new team = GetClientTeam(client);

    if ( team == CS_TEAM_T ) {
      ServerCommand("timeout_terrorist_start");
      PrintToChatAll("[\x04LO3\x01] Terrorit がタイムアウトを宣言しました");
      timeouted = true;
    }
    else if ( team == CS_TEAM_CT ) {
      ServerCommand("timeout_ct_start");
      PrintToChatAll("[\x04LO3\x01] CT がタイムアウトを宣言しました");
      timeouted = true;
    }
  }
}

public coach(client) {
  if ( GetConVarInt(cvar_sv_coaching_enabled) == 1 ) {
    new team = GetClientTeam(client);

    if (team == CS_TEAM_T) {
      ClientCommand(client, "coach t");
    }
    else if (team == CS_TEAM_CT) {
      ClientCommand(client, "coach ct");
    }
  }
  else {
    PrintToChat(client, "[\x04LO3\x01] コーチモードはサーバーにより許可されていません");
  }
}

public coacht(client) {
  if ( GetConVarInt(cvar_sv_coaching_enabled) == 1 ) {
    ClientCommand(client, "coach t");
  }
  else {
    PrintToChat(client, "[\x04LO3\x01] コーチモードはサーバーにより許可されていません");
  }
}

public coachct(client) {
  if ( GetConVarInt(cvar_sv_coaching_enabled) == 1 ) {
    ClientCommand(client, "coach ct");
  }
  else {
    PrintToChat(client, "[\x04LO3\x01] コーチモードはサーバーにより許可されていません");
  }
}

public clinchvote(client) {
  if ( GetConVarInt(cvar_lo3_tournament_mode) == 0) {
    if ( nowphase == 0 )  {
      new team = GetClientTeam(client);

      if ( team == CS_TEAM_T ) {
        clinchvote_t = true;
      }
      else if ( team == CS_TEAM_CT ) {
        clinchvote_ct = true;
      }
    }
  }
  else {
    PrintToChatAll("[\x04LO3\x01] 許可されていないコマンドです");
  }
}

public clinchunvote(client) {
  if ( GetConVarInt(cvar_lo3_tournament_mode) == 0) {
    if ( nowphase == 0 )  {
      new team = GetClientTeam(client);

      if ( team == CS_TEAM_T ) {
        clinchvote_t = false;
      }
      else if ( team == CS_TEAM_CT ) {
        clinchvote_ct = false;
      }
    }
  }
  else {
    PrintToChatAll("[\x04LO3\x01] 許可されていないコマンドです");
  }
}

public matchstop(client) {
  if ( nowphase != 0 ) {
    if ( GetConVarInt(cvar_lo3_tournament_mode) == 1) {
      new team = GetClientTeam(client);

      if (team == CS_TEAM_T) {
        matchstop_t = true;
      }
      else if (team == CS_TEAM_CT) {
        matchstop_ct = true;
      }

      if ( matchstop_t && matchstop_ct ) {
        nowphase = 0;
        reset_stat();
        ServerCommand("mp_unpause_match");
        ServerCommand("mp_warmup_start");
        PrintToChatAll("[\x04LO3\x01] \x02試合が中断されました");
      }
      else if ( matchstop_t && !matchstop_ct ) {
        PrintToChatAll("[\x04LO3\x01] \x02Terrorist が試合の強制中断を希望しています");
        PrintToChatAll("[\x04LO3\x01] 試合を中断するにはCTチームが \x02!stop \x01と発言してください");
        PrintToChatAll("[\x04LO3\x01] このステータスはラウンド終了時にリセットされます");
      }
      else if ( !matchstop_t && matchstop_ct ) {
        PrintToChatAll("[\x04LO3\x01] \x02CT が試合の強制終了を希望しています");
        PrintToChatAll("[\x04LO3\x01] 試合を中断するにはTチームが \x02!stop \x01と発言してください");
        PrintToChatAll("[\x04LO3\x01] このステータスはラウンド終了時にリセットされます");
      }
    }
    else {
      nowphase = 0;
      reset_stat();
      ServerCommand("mp_unpause_match");
      ServerCommand("mp_warmup_start");
      PrintToChatAll("[\x04LO3\x01] \x02試合が中断されました");
    }
  }
}

public knife_switch(client) {
  if ( nowphase == 3 ) {
    new team = GetClientTeam(client);

    if ( team == CS_TEAM_T && knife_winteam == 1 ) {
      KillTimer(message_timer);
      message_timer = null;
      ServerCommand("mp_swapteams")
      PrintToChatAll("[\x04LO3\x01] チームが変更されます");
      PrintToChatAll("[\x04LO3\x01] \x0410秒後に試合が開始されます");
      nowphase = 4;
    }
    else if ( team == CS_TEAM_CT && knife_winteam == 2 ) {
      KillTimer(message_timer);
      message_timer = null;
      ServerCommand("mp_swapteams")
      PrintToChatAll("[\x04LO3\x01] チームが変更されます");
      PrintToChatAll("[\x04LO3\x01] \x0410秒後に試合が開始されます");
      nowphase = 4;
    }
  }
}

public knife_stay(client) {
  if ( nowphase == 3 ) {
    new team = GetClientTeam(client);

    if ( team == CS_TEAM_T && knife_winteam == 1 ) {
      KillTimer(message_timer);
      message_timer = null;
      PrintToChatAll("[\x04LO3\x01] \x0410秒後に試合が開始されます");
      reset_stat();
      ServerCommand("mp_warmuptime 10");
      ServerCommand("mp_warmup_pausetimer 0");
      nowphase = 1;
    }
    else if (team == CS_TEAM_CT && knife_winteam == 2 ) {
      KillTimer(message_timer);
      message_timer = null;
      PrintToChatAll("[\x04LO3\x01] \x0410秒後に試合が開始されます");
      reset_stat();
      ServerCommand("mp_warmuptime 10");
      ServerCommand("mp_warmup_pausetimer 0");
      nowphase = 1;
    }
  }
}

public scramble(client) {
  if ( GetConVarInt(cvar_lo3_tournament_mode) == 0) {
    if ( nowphase == 0 ) {
      ServerCommand("mp_scrambleteams")
      PrintToChatAll("[\x04LO3\x01] チームがシャッフルされます");
    }
    else {
      PrintToChatAll("[\x04LO3\x01] ウォームアップ中のみ実行できます");
    }
  }
  else {
    PrintToChatAll("[\x04LO3\x01] 許可されていないコマンドです");
  }
}

public swap(client) {
  if ( GetConVarInt(cvar_lo3_tournament_mode) == 0) {
    if ( nowphase == 0 ) {
      ServerCommand("mp_swapteams")
      PrintToChatAll("[\x04LO3\x01] チームが変更されます");
    }
    else {
      PrintToChatAll("[\x04LO3\x01] ウォームアップ中のみ実行できます");
    }
  }
  else {
    PrintToChatAll("[\x04LO3\x01] 許可されていないコマンドです");
  }
}

public mapchange(client) {
  if ( nowphase == 0 ) {
    ClientCommand(client, "menu_changemap");
  }
  else {
    PrintToChatAll("[\x04LO3\x01] 許可されていないコマンドです");
  }
}
