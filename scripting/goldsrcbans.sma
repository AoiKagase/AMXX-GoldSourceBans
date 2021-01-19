//------------------
//	Include Files
//------------------
#pragma semicolon 1

#include <amxmodx>
#include <amxmisc>
#include <geoip>
#include <fakemeta>
#include <sqlx>
#include <fun>

// Plugin
#define PLUGIN					"GoldSrcBans"
#define AUTHOR					"JonnyBoy0719, Aoi.Kagase"
#define VERSION					"2.0"
#define MaxClients				32

#define MAX_ERR_LENGTH			512
#define MAX_QUERY_LENGTH		2048
#define MAX_LENGTH				128

enum DB_CONFIG
{
	DB_HOST,
	DB_USER,
	DB_PASS,
	DB_TYPE,
	DB_NAME,
	DB_PREFIX,
}

// MySQL
//Database Handles
new Handle:g_dbTaple;
new Handle:g_dbConnect;
new g_dbConfig	[DB_CONFIG][MAX_LENGTH];
new g_dbError	[MAX_ERR_LENGTH];
new sql_cache	[MAX_QUERY_LENGTH + 1];
new const SQL_INSERT_GAG[] = 
	"INSERT INTO %s_comms (authid, name, created, ends, length, reason, aid, adminIp, sid, type) \
	 VALUES ('%s', '%s', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', IFNULL((SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '0'), '%s', %d, %d)";

new WebsiteAddress[128],
	serverID = -1,
	bool:HasLoadedBans = false,
	bool:HasLoadedGags = false;

new ServerIP[24],
	ServerPort[7];

// Player Gag
new bool:gag_chat[33],
	bool:gag_voice[33];

//------------------
//	plugin_init()
//------------------

public plugin_init()
{
	register_plugin	 (PLUGIN, VERSION, AUTHOR);
	register_cvar	 ("amx_goldsrcbans_version", VERSION, FCVAR_SPONLY|FCVAR_SERVER);
	set_cvar_string	 ("amx_goldsrcbans_version", VERSION);

	// SQL Cvar Setup
	bind_pcvar_string(create_cvar ("sourcebans_host", 	"127.0.0.1"), 	g_dbConfig[DB_HOST], 	charsmax(g_dbConfig[])); // The host from the db
	bind_pcvar_string(create_cvar ("sourcebans_user", 	"sourcebans"), 	g_dbConfig[DB_USER], 	charsmax(g_dbConfig[])); // The username from the db login
	bind_pcvar_string(create_cvar ("sourcebans_pass", 	"sourcebans"),	g_dbConfig[DB_PASS], 	charsmax(g_dbConfig[])); // The password from the db password
	bind_pcvar_string(create_cvar ("sourcebans_type", 	"mysql"),		g_dbConfig[DB_TYPE], 	charsmax(g_dbConfig[])); // The password from the db type
	bind_pcvar_string(create_cvar ("sourcebans_dbname", "sourcebans"),	g_dbConfig[DB_NAME], 	charsmax(g_dbConfig[])); // The database name
	bind_pcvar_string(create_cvar ("sourcebans_prefix", "sb"),			g_dbConfig[DB_PREFIX], 	charsmax(g_dbConfig[])); // The database prefix

	// Ban System
	register_concmd	 ("amx_ban", 	"CmdBanPlayer", 		ADMIN_BAN, "<#userid|name> <time> <timetype> [reason]");
	register_concmd	 ("amx_banip", 	"CmdBanPlayerIP", 		ADMIN_BAN, "<ip> <time> <timetype> [reason]");
	register_concmd	 ("amx_addban",	"CmdBanPlayerSteamID", 	ADMIN_BAN, "<time> <timetype> <steamid> [reason]");
	register_concmd	 ("amx_unban", 	"CmdUnBanPlayer", 		ADMIN_BAN, "<steamid|ip> [reason]");

	// Voice com and chat bans
	register_concmd	 ("amx_gag", 	"CmdGagPlayer", 		ADMIN_BAN, "<#userid|name> <time> <timetype> <type> [reason]");
	register_concmd	 ("amx_ungag", 	"CmdUnGagPlayer", 		ADMIN_BAN, "<#userid|name> <type> [reason]");

	// Client commands
	register_clcmd("say","say_hook");
	register_clcmd("say_team","say_hook");

	// Forwarding
	register_forward(FM_Voice_SetClientListening, "VoiceSetClientListening");

	CheckSourceBansFile();
}

//------------------
//	VoiceSetClientListening()
//------------------
public VoiceSetClientListening(receiver, sender, bool:bListen)
{
	if (!is_user_connected(receiver) || !is_user_connected(sender))
    	return FMRES_IGNORED;
	
	if (gag_voice[sender])
	{
		engfunc(EngFunc_SetClientListening, receiver, sender, 0);
		return FMRES_SUPERCEDE;
	}

	return FMRES_IGNORED;
}

//------------------
//	CmdGagPlayer()
//------------------
public CmdGagPlayer(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new szUserId	[32];	// <#userid|name|steamid>
	new	szTime		[32];	// <time>
	new	szTimeType	[32];	// <timetype>
	new	szGagType	[32];	// <0|1|2>
	new	szReason	[125];	// [reason]

	read_argv(1, szUserId, 	charsmax(szUserId));
	read_argv(2, szTime, 	charsmax(szTime));
	read_argv(3, szTimeType,charsmax(szTimeType));
	read_argv(4, szGagType, charsmax(szGagType));
	read_argv(5, szReason, 	charsmax(szReason));

	new iTimeType = str_to_num(szTimeType);
	new	iTime 	  = str_to_num(szTime);
	new	szTimeTypeMsg[32] = "";

	if ( iTimeType == -1 || iTimeType > 3 )
	{
		// TODO: Multi Language.
		client_print(id, print_console, "Available time types are:");
		client_print(id, print_console, "0 - minutes");
		client_print(id, print_console, "1 - hours");
		client_print(id, print_console, "2 - days");
		client_print(id, print_console, "3 - weeks");
		return PLUGIN_HANDLED;
	}

	switch( iTimeType )
	{
		// TODO: Multi Language.
		case 0:formatex(szTimeTypeMsg, charsmax(szTimeTypeMsg), "minute(s)");
		case 1:formatex(szTimeTypeMsg, charsmax(szTimeTypeMsg), "hour(s)");
		case 2:formatex(szTimeTypeMsg, charsmax(szTimeTypeMsg), "day(s)");
		case 3:formatex(szTimeTypeMsg, charsmax(szTimeTypeMsg), "week(s)");
	}

	if (!access(id, ADMIN_LEVEL_A))
	{
		client_print(id, print_console, "You do not have access to gag permanently.");
		return PLUGIN_HANDLED;
	}

	new player = cmd_target(id, szUserId, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);
	if (!player)
	{
		client_print(id, print_console, "Player ^"%s^" was not found!", szUserId);
		return PLUGIN_HANDLED;
	}

	// Check if he has access for permanent time
	if (iTime == 0)
	{
		client_print(id, print_console, "You do not have access to gag permanently.");
		return PLUGIN_HANDLED;
	}

	// Lets setup the time
	switch( iTimeType )
	{
		case 1:
			iTime = (iTime * 60); // Hours
		case 2:
			iTime = (iTime * 60 * 24); // Days
		case 3:
			iTime = (iTime * 60 * 24 * 7); // Weeks
	}

	// Then check, if we can ban more than 1 week.
	if (iTime > 10080)
	{
		client_print(id, print_console, "You do not have access to gag more than 1 week.");
		return PLUGIN_HANDLED;
	}

	new iGagType = str_to_num(szGagType);

	if (iGagType < 0 || iGagType > 2)
	{
		client_print(id, print_console, "allowed types are:");
		client_print(id, print_console, "0 - silence");
		client_print(id, print_console, "1 - mute");
		client_print(id, print_console, "2 - gag");
		return PLUGIN_HANDLED;
	}

	GagPlayer(id, player, str_to_num(szTime), iTime, iGagType, szReason, szTimeTypeMsg, false);

	return PLUGIN_HANDLED;
}
//------------------
//	CmdUnGagPlayer()
//------------------

public CmdUnGagPlayer(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new szUserId	[32];	// <userid>
	new	szType		[32];	// <type>
	new	szReason	[125];	// [reason]

	read_argv(1, szUserId, 	charsmax(szUserId));
	read_argv(2, szType, 	charsmax(szType));
	read_argv(3, szReason, 	charsmax(szReason));

	// STEAM_ID or #id.
	new player = cmd_target(id, szUserId, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);

	if (!player)
	{
		client_print(id, print_console, "Player ^"%s^" was not found!", szUserId);
		return PLUGIN_HANDLED;
	}

	if (equali(szReason, ""))
		formatex(szReason, charsmax(szReason), "No Reason given.");

	UnGagPlayer(id, player, str_to_num(szType), szReason, false);

	return PLUGIN_HANDLED;
}

//------------------
//	CmdUnBanPlayer()
//------------------

public CmdUnBanPlayer(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[32],	// <steamid>
		arg2[125];	// [reason]

	read_argv(1, arg, 31);
	read_argv(2, arg2, 124);

	if (equali(arg2, ""))
		arg2 = "No Reason given.";

	if (containi(arg, "STEAM_") != -1)
		formatex(sql_cache, charsmax(sql_cache), "SELECT bid FROM %s_bans WHERE (type = 0 AND authid = '%s') AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], arg);
	else
		formatex(sql_cache, charsmax(sql_cache), "SELECT bid FROM %s_bans WHERE (type = 1 AND ip = '%s') AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], arg);

	new Handle:query = SQL_PrepareQuery(g_dbConnect, sql_cache);

	if (!SQL_Execute(query))
	{
		server_print("query not saved");
		SQL_QueryError(query, g_dbError, charsmax(g_dbError));
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_LOAD_ADMINS", g_dbError);
	}
	else if (SQL_NumResults(query) >= 1)
	{
		new Name[32],
			adminAuth[64],
			adminIp[64];

		get_user_name(id, Name, 31);
		get_user_authid(id, adminAuth, 63);
		get_user_ip(id, adminIp, 63);

		replace_all( Name, 2500, "`", "\`");
		replace_all( Name, 2500, "'", "\'");

		replace_all( arg2, 2500, "`", "\`");
		replace_all( arg2, 2500, "'", "\'");

		// Grab the bid
		new bid,
			sql_bid;

		bid = SQL_FieldNameToNum(query, "bid");

		while (SQL_MoreResults(query))
		{
			sql_bid = SQL_ReadResult(query, bid);
			SQL_NextRow(query);
		}

		format(sql_cache, charsmax(sql_cache), "UPDATE %s_bans SET RemovedBy = (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), RemoveType = 'U', RemovedOn = UNIX_TIMESTAMP(), ureason = '%s' WHERE bid = %d", 
			g_dbConfig[DB_PREFIX], g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], arg2, sql_bid);

		SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);
	}
	else
	{
		if (id && is_user_connected(id))
			client_print(id, print_chat, "No active bans found for that filter");
		else
			log_amx("No active bans found for that filter!");
	}

	new authid[32],
		name[32];

	get_user_authid(id, authid, 31);
	get_user_name(id, name, 31);

	log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" has unbanned ^"%s^" - reason: ^"%s^"", name, get_user_userid(id), authid, arg, arg2);

	new formated_text[501];
	format(formated_text, 500, "[SourceBans] ^"%s<%s>^" has unbanned ^"%s^" - reason: ^"%s^"", name, authid, arg, arg2);
	PrintToAdmins(formated_text);

	SQL_FreeHandle(query);

	return PLUGIN_HANDLED;
}

//------------------
//	CmdBanPlayer()
//------------------

public CmdBanPlayer(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[32],	// <#userid|name|steamid>
		arg2[32],	// <time>
		arg3[32],	// <timetype>
		arg4[125];	// [reason]

	new bool:SteamID = false,
		bool:IsConsole = false;

	if (id == 0)
		IsConsole = true;

	read_argv(1, arg, 31);
	read_argv(2, arg2, 31);
	read_argv(3, arg3, 31);
	read_argv(4, arg4, 124);
	
	new timetype = str_to_num(arg3),
		timeSetup = str_to_num(arg2),
		timetypeSTR[32] = "";
	
	if ( timetype == -1 || timetype > 3 )
	{
		client_print(id, print_console, "Available time types are:");
		client_print(id, print_console, "0 - minutes");
		client_print(id, print_console, "1 - hours");
		client_print(id, print_console, "2 - days");
		client_print(id, print_console, "3 - weeks");
		return PLUGIN_HANDLED;
	}

	switch( timetype )
	{
		case 0:
			timetypeSTR = "minute(s)";
		case 1:
			timetypeSTR = "hour(s)";
		case 2:
			timetypeSTR = "day(s)";
		case 3:
			timetypeSTR = "week(s)";
	}

	// Check if he has access for permanent time
	if (str_to_num(arg2) == 0 && !access(id, ADMIN_LEVEL_A))
	{
		client_print(id, print_console, "You do not have access to ban permanently.");
		return PLUGIN_HANDLED;
	}
	// Then check, if we can ban more than 1 week.
	else if (str_to_num(arg2) > 10080 && !access(id, ADMIN_LEVEL_A) && timetype == 0 )
	{
		client_print(id, print_console, "You do not have access to ban more than 1 week.");
		return PLUGIN_HANDLED;
	}
	// Check the hours
	else if (str_to_num(arg2) > 168 && !access(id, ADMIN_LEVEL_A) && timetype == 1 )
	{
		client_print(id, print_console, "You do not have access to ban more than 1 week.");
		return PLUGIN_HANDLED;
	}
	// Check the days
	else if (str_to_num(arg2) > 7 && !access(id, ADMIN_LEVEL_A) && timetype == 2 )
	{
		client_print(id, print_console, "You do not have access to ban more than 1 week.");
		return PLUGIN_HANDLED;
	}
	// Check the weeks
	else if (str_to_num(arg2) > 1 && !access(id, ADMIN_LEVEL_A) && timetype == 3 )
	{
		client_print(id, print_console, "You do not have access to ban more than 1 week.");
		return PLUGIN_HANDLED;
	}

	new player = cmd_target(id, arg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);

	new iPlayers[32],
		PlayerSteamID[32],
		iNum;

	get_players(iPlayers, iNum);
	for(new i = 0;i < iNum; i++)
	{
		new players = iPlayers[i];
		if(is_user_connected(players))
		{
			get_user_authid(players, PlayerSteamID, 31);
			if (equali(PlayerSteamID, arg))
			{
				player = players;
				SteamID = true;
				break;
			}
		}
	}

	if (!player && !SteamID)
	{
		client_print(id, print_console, "Player ^"%s^" was not found!", arg);
		return PLUGIN_HANDLED;
	}

	new authid[32],
		authid2[32],
		name[32],
		name2[32];

	get_user_authid(id, authid, 31);
	get_user_authid(player, authid2, 31);
	get_user_name(id, name, 31);
	get_user_name(player, name2, 31);

	if (equali(arg4, ""))
		arg4 = "No Reason given.";

	// Lets setup the time
	switch( timetype )
	{
		case 1:
			timeSetup = (timeSetup * 60); // Hours
		case 2:
			timeSetup = (timeSetup * 60 * 24); // Days
		case 3:
			timeSetup = (timeSetup * 60 * 24 * 7); // Weeks
	}

	if( timeSetup == 0 )
		timetypeSTR = "permanently";

	if ( IsConsole )
		log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" has been banned for %d %s - reason: ^"%s^"", name2, get_user_userid(player), authid2, str_to_num(arg2), timetypeSTR, arg4);
	else
		log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" has banned ^"%s<%d><%s><>^" for %d %s - reason: ^"%s^"", name, get_user_userid(id), authid, name2, get_user_userid(player), authid2, str_to_num(arg2), timetypeSTR, arg4);

	new formated_text[501];

	if ( IsConsole )
		format(formated_text, 500, "[SourceBans] ^"%s<%s>^" has been banned for %d %s - reason: ^"%s^"", name2, authid2, str_to_num(arg2), timetypeSTR, arg4);
	else
		format(formated_text, 500, "[SourceBans] ^"%s<%s>^" has banned ^"%s<%s>^" for %d %s - reason: ^"%s^"", name, authid, name2, authid2, str_to_num(arg2), timetypeSTR, arg4);

	PrintToAdmins(formated_text);

	if ( IsConsole )
		format(formated_text, 500, "[SourceBans] ^"%s^" has banned for %d %s - reason: ^"%s^"", name2, str_to_num(arg2), timetypeSTR, arg4);
	else
		format(formated_text, 500, "[SourceBans] ^"%s^" has banned ^"%s^" for %d %s - reason: ^"%s^"", name, name2, str_to_num(arg2), timetypeSTR, arg4);

	PrintToNonAdmin(formated_text);

	BanPlayer(id, player, timeSetup, arg4);

	return PLUGIN_HANDLED;
}



//------------------
//	CmdBanPlayerIP()
//------------------

public CmdBanPlayerIP(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[32],	// <ip>
		arg2[32],	// <time>
		arg3[32],	// <timetype>
		arg4[125];	// [reason]

	read_argv(1, arg, 31);
	read_argv(2, arg2, 31);
	read_argv(3, arg3, 31);
	read_argv(4, arg4, 124);

	new timetype = str_to_num(arg3),
		timetypeSTR[32] = "";

	if ( timetype == -1 || timetype > 3 )
	{
		client_print(id, print_console, "Available time types are:");
		client_print(id, print_console, "0 - minutes");
		client_print(id, print_console, "1 - hours");
		client_print(id, print_console, "2 - days");
		client_print(id, print_console, "3 - weeks");
		return PLUGIN_HANDLED;
	}

	switch( timetype )
	{
		case 0:
			timetypeSTR = "minute(s)";
		case 1:
			timetypeSTR = "hour(s)";
		case 2:
			timetypeSTR = "day(s)";
		case 3:
			timetypeSTR = "week(s)";
	}

	if (equali(arg4, ""))
		arg4 = "No Reason given.";

	new time = str_to_num(arg2);

	new Handle:query = SQL_PrepareQuery(g_dbConnect, "SELECT bid FROM %s_bans WHERE type = 1 AND ip = '%s' AND (length = 0 OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], arg);

	if (!SQL_Execute(query))
	{
		server_print("query not saved");
		SQL_QueryError(query, g_dbError, charsmax(g_dbError));
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_LOAD_ADMINS", g_dbError);
	} else {
		if (id && is_user_connected(id))
			client_print(id, print_chat, "%s is already banned!", arg);
		else
			log_amx("%s is already banned!", arg);
	}

	new Name[32],
		adminAuth[64],
		adminIp[64];

	get_user_name(id, Name, 31);
	get_user_authid(id, adminAuth, 63);
	get_user_ip(id, adminIp, 63);

	replace_all( Name, 2500, "`", "\`");
	replace_all( Name, 2500, "'", "\'");

	replace_all( arg4, 2500, "`", "\`");
	replace_all( arg4, 2500, "'", "\'");

	// Lets setup the time
	switch( timetype )
	{
		case 1:
			time = (time * 60); // Hours
		case 2:
			time = (time * 60 * 24); // Days
		case 3:
			time = (time * 60 * 24 * 7); // Weeks
	}

	if (serverID == -1)
	{
		formatex(sql_cache, sizeof(sql_cache), "INSERT INTO %s_bans (type, ip, name, created, ends, length, reason, aid, adminIp, sid, country) VALUES \
						(1, '%s', '', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '%s', \
						(SELECT sid FROM %s_servers WHERE ip = '%s' AND port = '%s' LIMIT 0,1), ' ')", 
			g_dbConfig[DB_PREFIX], arg, (time * 60), (time * 60), arg4, g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], adminIp, g_dbConfig[DB_PREFIX], ServerIP, ServerPort);
	} else {
		formatex(sql_cache, sizeof(sql_cache), "INSERT INTO %s_bans (type, ip, name, created, ends, length, reason, aid, adminIp, sid, country) VALUES \
						(1, '%s', '', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '%s', \
						%d, ' ')", 
			g_dbConfig[DB_PREFIX], arg, (time * 60), (time * 60), arg4, g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], adminIp, serverID);
	}

	if( time == 0 )
		timetypeSTR = "permanently";

	SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);

	log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" banned the ip ^"%s^" for %d %s - reason: %s", Name, get_user_userid(id), adminAuth, arg, time, timetypeSTR, arg4);

	new formated_text[501];
	format(formated_text, 500, "[SourceBans] ^"%s<%s>^" banned the ip ^"%s^" for %d %s - reason: %s", Name, adminAuth, arg, time, timetypeSTR, arg4);
	PrintToAdmins(formated_text);
	format(formated_text, 500, "[SourceBans] ^"%s^" banned the ip ^"%s^" for %d %s - reason: %s", Name, arg, time, timetypeSTR, arg4);
	PrintToNonAdmin(formated_text);

	SQL_FreeHandle(query);

	return PLUGIN_HANDLED;
}

//------------------
//	CmdBanPlayerSteamID()
//------------------

public CmdBanPlayerSteamID(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	new arg[32],	// <time>
		arg1[32],	// <timetype>
		arg2[32],	// <steamid>
		arg3[125];	// [reason]

	read_argv(1, arg, 31);
	read_argv(2, arg1, 31);
	read_argv(3, arg2, 31);
	read_argv(4, arg3, 124);

	new timetype = str_to_num(arg1),
		timetypeSTR[32] = "";

	if ( timetype == -1 || timetype > 3 )
	{
		client_print(id, print_console, "Available time types are:");
		client_print(id, print_console, "0 - minutes");
		client_print(id, print_console, "1 - hours");
		client_print(id, print_console, "2 - days");
		client_print(id, print_console, "3 - weeks");
		return PLUGIN_HANDLED;
	}

	switch( timetype )
	{
		case 0:
			timetypeSTR = "minute(s)";
		case 1:
			timetypeSTR = "hour(s)";
		case 2:
			timetypeSTR = "day(s)";
		case 3:
			timetypeSTR = "week(s)";
	}

	if (equali(arg3, ""))
		arg3 = "No Reason given.";

	new Handle:query = SQL_PrepareQuery(g_dbConnect, "SELECT bid FROM %s_bans WHERE type = 0 AND authid = '%s' AND (length = 0 OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], arg2);

	if (!SQL_Execute(query))
	{
		server_print("query not saved");
		SQL_QueryError(query, g_dbError, charsmax(g_dbError));
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_LOAD_ADMINS", g_dbError);
	} else {
		if (id && is_user_connected(id))
			client_print(id, print_chat, "%s is already banned!", arg2);
		else
			log_amx("%s is already banned!", arg2);
	}
	
	new time = str_to_num(arg);

	new Name[32],
		adminAuth[64],
		adminIp[64];

	get_user_name(id, Name, 31);
	get_user_authid(id, adminAuth, 63);
	get_user_ip(id, adminIp, 63);

	replace_all( Name, 2500, "`", "\`");
	replace_all( Name, 2500, "'", "\'");

	replace_all( arg3, 2500, "`", "\`");
	replace_all( arg3, 2500, "'", "\'");

	// Lets setup the time
	switch( timetype )
	{
		case 1:
			time = (time * 60); // Hours
		case 2:
			time = (time * 60 * 24); // Days
		case 3:
			time = (time * 60 * 24 * 7); // Weeks
	}

	if (serverID == -1)
	{
		formatex(sql_cache, sizeof(sql_cache), "INSERT INTO %s_bans (authid, name, created, ends, length, reason, aid, adminIp, sid, country) VALUES \
						('%s', '', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '%s', \
						(SELECT sid FROM %s_servers WHERE ip = '%s' AND port = '%s' LIMIT 0,1), ' ')", 
			g_dbConfig[DB_PREFIX], arg2, (time * 60), (time * 60), arg3, g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], adminIp, g_dbConfig[DB_PREFIX], ServerIP, ServerPort);
	} else {
		formatex(sql_cache, sizeof(sql_cache), "INSERT INTO %s_bans (authid, name, created, ends, length, reason, aid, adminIp, sid, country) VALUES \
						('%s', '', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '%s', \
						%d, ' ')", 
			g_dbConfig[DB_PREFIX], arg2, (time * 60), (time * 60), arg3, g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], adminIp, serverID);
	}

	SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);

	if( time == 0 )
		timetypeSTR = "permanently";

	log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" banned the SteamID ^"%s^" for %d %s - reason: %s", Name, get_user_userid(id), adminAuth, arg2, time, timetypeSTR, arg3);

	new formated_text[501];
	format(formated_text, 500, "[SourceBans] ^"%s<%s>^" banned the SteamID ^"%s^" for %d %s - reason: %s", Name, adminAuth, arg2, time, timetypeSTR, arg3);
	PrintToAdmins(formated_text);
	format(formated_text, 500, "[SourceBans] ^"%s^" banned the SteamID ^"%s^" for %d %s - reason: %s", Name, arg2, time, timetypeSTR, arg3);
	PrintToNonAdmin(formated_text);

	SQL_FreeHandle(query);

	return PLUGIN_HANDLED;
}

//------------------
//	plugin_cfg()
//------------------

public plugin_cfg()
{
	// Lets delay the connection
	set_task( 2.3, "SQL_Init", 0 );

	// Grab the server IP and port
	get_cvar_string("ip", ServerIP, sizeof(ServerIP));
	get_cvar_string("port", ServerPort, sizeof(ServerPort));
}

//------------------
//	plugin_end()
//------------------

public plugin_end()
{
	// Lets close down the connection
	if (g_dbTaple)
		SQL_FreeHandle(g_dbTaple);
	if (g_dbConnect)
		SQL_FreeHandle(g_dbConnect);
}

//------------------
//	client_authorized()
//------------------

public client_authorized(id)
{
	if (IsValidClient(id))
		CheckIfBanned(id);
}

//------------------
//	client_putinserver()
//------------------

public client_putinserver(id)
{
	CheckIfGagged(id);
}

//------------------
//	say_hook()
//------------------

public say_hook(id)
{
	if (gag_chat[id])
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

//------------------
//	CheckSourceBansFile()
//------------------

public CheckSourceBansFile()
{
	new GetconfigsDir[64],
		configsDir[64];

	get_configsdir(GetconfigsDir, 63);
	format(configsDir, 63, "%s/goldsrcbans/settings.cfg", GetconfigsDir);

	if (!file_exists(configsDir))
	{
		server_print("[CheckSourceBansFile] File ^"%s^" doesn't exist.", configsDir);
		return;
	}

	new File=fopen(configsDir,"r");
	if (File)
	{
		new ConfigString[512],
			CommandID[32],
			ValueID[32];

		while (!feof(File))
		{
			fgets(File, ConfigString, sizeof(ConfigString)-1);

			trim(ConfigString);

			// comment
			if (ConfigString[0]==';' || ConfigString[0]==' ')
				continue;

			CommandID[0]=0;
			ValueID[0]=0;

			// not enough parameters
			if (parse(ConfigString, CommandID, sizeof(CommandID)-1, ValueID, sizeof(ValueID)-1) < 2)
				continue;

			if (equali(CommandID, "website"))
				WebsiteAddress = ValueID;

			if (equali(CommandID, "serverid"))
				serverID = str_to_num(ValueID);
		}
		fclose(File);
	}
}

//------------------
//	CheckIfBanned()
//------------------

stock CheckIfBanned(id)
{
	if (!id)
		return;

	new auth[64],
		ip[64];

	get_user_authid(id, auth, 63);
	get_user_ip(id, ip, 63);

	formatex( sql_cache, sizeof(sql_cache), "SELECT bid FROM %s_bans WHERE ((type = 0 AND authid REGEXP '^^STEAM_[0-9]:%s$') OR (type = 1 AND ip = '%s')) AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], auth[8], ip);
	new send_id[1];
	send_id[0] = id;

	SQL_ThreadQuery(g_dbTaple, "CheckBannedPlayer", sql_cache, send_id, 1);
}

//------------------
//	CheckIfGagged()
//------------------

stock CheckIfGagged(id)
{
	if (!id)
		return;

	new auth[64],
		ip[64];

	get_user_authid(id, auth, 63);
	get_user_ip(id, ip, 63);

	formatex( sql_cache, sizeof(sql_cache), "SELECT bid,type FROM %s_comms WHERE authid REGEXP '^^STEAM_[0-9]:%s$' AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], auth[8], ip);
	new send_id[1];
	send_id[0] = id;

	SQL_ThreadQuery(g_dbTaple, "CheckGaggedPlayers", sql_cache, send_id, 1);
}

//------------------
//	BanPlayer()
//------------------

stock BanPlayer(admin, victim, time, banReason[])
{
	if (!admin && admin > 0)
		return;

	new bool:IsConsole = false;

	if (admin == 0)
		IsConsole = true;

	if (!victim)
		return;

	new AdminAuthid[64],
		AdminName[32],
		Name[32],
		Ip[64],
		Authid[64],
		AdminIp[64];

	replace_all( banReason, 2500, "`", "\`");
	replace_all( banReason, 2500, "'", "\'");

	if (!IsConsole)
	{
		get_user_name(admin, AdminName, 31);
		get_user_authid(admin, AdminAuthid, 63);
		get_user_ip(admin, AdminIp, 63);
	}
	else
	{
		AdminName = "Console";
		AdminAuthid = "";
		AdminIp = ServerIP;
	}

	get_user_name(victim, Name, 31);
	get_user_authid(victim, Authid, 63);
	get_user_ip(victim, Ip, 63);

	replace_all( Name, 2500, "`", "\`");
	replace_all( Name, 2500, "'", "\'");

	replace_all( AdminName, 2500, "`", "\`");
	replace_all( AdminName, 2500, "'", "\'");

	formatex( sql_cache, sizeof(sql_cache), "INSERT INTO %s_bans (ip, authid, name, created, ends, length, reason, aid, adminIp, sid, country) VALUES \
					('%s', '%s', '%s', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', IFNULL((SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'),'0'), '%s', \
					(SELECT sid FROM %s_servers WHERE ip = '%s' AND port = '%s' LIMIT 0,1), ' ')", 
		g_dbConfig[DB_PREFIX], Ip, Authid, Name, (time * 60), (time * 60), banReason, g_dbConfig[DB_PREFIX], AdminAuthid, AdminAuthid[8], AdminIp, g_dbConfig[DB_PREFIX], ServerIP, ServerPort);

	SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);

	server_cmd("kick #%d ^"%s^"", get_user_userid(victim), banReason);
}

//------------------
//	GagPlayer()
//------------------

stock GagPlayer(admin, victim, timereal, time, type, banReason[], GagStringSetup[], bool:IsSilence)
{
	if (!admin && admin > 0)
		return;

	new bool:IsConsole = false;

	if (admin == 0)
		IsConsole = true;

	if (!victim)
		return;

	new type_sql = type;

	new AdminAuthid[64],
		AdminName[32],
		Name[32],
		Ip[64],
		Authid[64],
		TypeName[64],
		TimeString[64],
		AdminIp[64];

	replace_all( banReason, 2500, "`", "\`");
	replace_all( banReason, 2500, "'", "\'");

	if (!IsConsole)
	{
		get_user_name(admin, AdminName, 31);
		get_user_authid(admin, AdminAuthid, 63);
		get_user_ip(admin, AdminIp, 63);
	}
	else
	{
		AdminName = "Console";
		AdminAuthid = "";
		AdminIp = ServerIP;
	}

	get_user_name(victim, Name, 31);
	get_user_authid(victim, Authid, 63);
	get_user_ip(victim, Ip, 63);

	replace_all( Name, 2500, "`", "\`");
	replace_all( Name, 2500, "'", "\'");

	replace_all( AdminName, 2500, "`", "\`");
	replace_all( AdminName, 2500, "'", "\'");

	if (type_sql == 0)
		type_sql = 1;

	formatex(sql_cache, sizeof(sql_cache), SQL_INSERT_GAG, 
			g_dbConfig[DB_PREFIX], 
			Authid, 
			Name, 
			(time * 60), 
			(time * 60), 
			banReason, 
			g_dbConfig[DB_PREFIX], 
			AdminAuthid, 
			AdminAuthid[8], 
			AdminIp, 
			serverID, 
			type_sql);

	SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);

	if (!IsSilence)
	{
		if (type == 0)
		{
			TypeName = "silenced";
			gag_chat[victim] = true;
			gag_voice[victim] = true;
		}
		else if (type == 1)
		{
			TypeName = "muted";
			gag_voice[victim] = true;
		}
		else
		{
			TypeName = "gagged";
			gag_chat[victim] = true;
		}

		log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" has %s ^"%s<%d><%s><>^" %s - reason: ^"%s^"", AdminName, get_user_userid(admin), AdminAuthid, TypeName, Name, get_user_userid(victim), Authid, TimeString, banReason);

		if (time == 0)
			format(TimeString, sizeof(TimeString), "permanently");
		else
			format(TimeString, sizeof(TimeString), "for %d %s", timereal, GagStringSetup);

		new formated_text[501];
		format(formated_text, 500, "[SourceBans] ^"%s<%s>^" has %s ^"%s<%s>^" %s - reason: ^"%s^"", AdminName, AdminAuthid, TypeName, Name, Authid, TimeString, banReason);
		PrintToAdmins(formated_text);
		format(formated_text, 500, "[SourceBans] ^"%s^" has %s ^"%s^" %s - reason: ^"%s^"", AdminName, TypeName, Name, TimeString, banReason);
		PrintToNonAdmin(formated_text);

		// Lets gag on chat, if silence is on
		if (type == 0)
			GagPlayer(admin, victim, timereal, time, 2, banReason, GagStringSetup, true);
	}
}

//------------------
//	UnGagPlayer()
//------------------

stock UnGagPlayer(admin, victim, type, banMessage[], bool:IsSilence)
{
	new authid[32],
		authid2[32],
		TypeName[32],
		name[32],
		name2[32],
		type_sql;

	type_sql = type;

	get_user_authid(admin, authid, 31);
	get_user_authid(victim, authid2, 31);
	get_user_name(admin, name, 31);
	get_user_name(victim, name2, 31);

	if (type_sql == 0)
		type_sql = 1;

	formatex(sql_cache, charsmax(sql_cache), "SELECT bid FROM %s_comms WHERE (type = %d AND authid = '%s') AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL", g_dbConfig[DB_PREFIX], type_sql, authid);

	new Handle:query = SQL_PrepareQuery(g_dbConnect, sql_cache);

	if (!SQL_Execute(query))
	{
		server_print("query not saved");
		SQL_QueryError(query, g_dbError, charsmax(g_dbError));
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_LOAD_ADMINS", g_dbError);
	}
	else if (SQL_NumResults(query) >= 1)
	{
		new Name[32],
			adminAuth[64],
			adminIp[64];

		get_user_name(admin, Name, 31);
		get_user_authid(admin, adminAuth, 63);
		get_user_ip(admin, adminIp, 63);

		replace_all( Name, 2500, "`", "\`");
		replace_all( Name, 2500, "'", "\'");

		replace_all( banMessage, 2500, "`", "\`");
		replace_all( banMessage, 2500, "'", "\'");

		// Grab the bid
		new bid,
			sql_bid;

		bid = SQL_FieldNameToNum(query, "bid");

		while (SQL_MoreResults(query))
		{
			sql_bid = SQL_ReadResult(query, bid);
			SQL_NextRow(query);
		}

		format(sql_cache, charsmax(sql_cache), "UPDATE %s_comms SET RemovedBy = (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), RemoveType = 'U', RemovedOn = UNIX_TIMESTAMP(), ureason = '%s' WHERE bid = %d", 
			g_dbConfig[DB_PREFIX], g_dbConfig[DB_PREFIX], adminAuth, adminAuth[8], banMessage, sql_bid);

		SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);
	}
	else
	{
		if (admin && is_user_connected(admin))
			client_print(admin, print_chat, "No active bans found for that filter");
		else
			log_amx("No active bans found for that filter!");
	}

	if (!IsSilence)
	{
		if (type == 0)
		{
			TypeName = "unsilenced";
			gag_chat[victim] = false;
			gag_voice[victim] = false;
		}
		else if (type == 1)
		{
			TypeName = "unmuted";
			gag_voice[victim] = false;
		}
		else
		{
			TypeName = "ungagged";
			gag_chat[victim] = false;
		}

		log_amx("GoldSrcBans CMD: ^"%s<%d><%s><>^" has %s ^"%s<%d><%s><>^" - reason: ^"%s^"", name, get_user_userid(admin), authid, TypeName, name2, get_user_userid(victim), authid2, banMessage);

		new formated_text[501];
		format(formated_text, 500, "[SourceBans] ^"%s<%s>^" has %s ^"%s<%s>^" - reason: ^"%s^"", name, authid, TypeName, name2, authid2, banMessage);
		PrintToAdmins(formated_text);
		format(formated_text, 500, "[SourceBans] ^"%s^" has %s ^"%s^" - reason: ^"%s^"", name, TypeName, name2, banMessage);
		PrintToNonAdmin(formated_text);
	}

	SQL_FreeHandle(query);

	// Was it silence?
	if (type == 0)
		UnGagPlayer(admin, victim, 2, banMessage, true);
}

//------------------
//	IsValidClient()
//------------------

stock bool:IsValidClient(client)
{
	if(client < 1 || client > MaxClients) return false;
	if(!is_user_connected(client)) return false;
	return true;
}

// ============================================================//
//                          [~ MySQL DATA ~]			       //
// ============================================================//

//------------------
//	SQL_Init()
//------------------

public SQL_Init()
{
	new error[MAX_ERR_LENGTH + 1];
	new ercode;

//	SQL_GetAffinity(get_type, 12);

	g_dbTaple 	= SQL_MakeDbTuple(
		g_dbConfig[DB_HOST],
		g_dbConfig[DB_USER],
		g_dbConfig[DB_PASS],
		g_dbConfig[DB_NAME]
	);
	g_dbConnect = SQL_Connect(g_dbTaple, ercode, error, charsmax(error));

	if (g_dbConnect == Empty_Handle)
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_CON", error);

	// check if the table exist
	formatex( sql_cache, charsmax(sql_cache), "show tables like '%s_bans'", g_dbConfig[DB_PREFIX] );
	SQL_ThreadQuery( g_dbTaple, "ShowBansTable", sql_cache );	

	formatex( sql_cache, charsmax(sql_cache), "show tables like '%s_comms'", g_dbConfig[DB_PREFIX] );
	SQL_ThreadQuery( g_dbTaple, "ShowGagsTable", sql_cache );	
}

//------------------
//	ShowBansTable()
//------------------

public ShowBansTable(FailState,Handle:Query,Error[],Errcode,Data[],DataSize)
{
	if(FailState==TQUERY_CONNECT_FAILED){
		log_amx( "[SourceBans] Could not connect to SQL database." );
		log_amx( "[SourceBans] Bans won't be loaded" );
		HasLoadedBans = false;
		return PLUGIN_CONTINUE;
	}
	else if (FailState == TQUERY_QUERY_FAILED)
	{
		log_amx( "[SourceBans] Query failed." );
		log_amx( "[SourceBans] Bans won't be loaded" );
		HasLoadedBans = false;
		return PLUGIN_CONTINUE;
	}

	if (Errcode)
	{
		log_amx( "[SourceBans] Error on query: %s", Error );
		log_amx( "[SourceBans] Bans won't be loaded" );
		HasLoadedBans = false;
		return PLUGIN_CONTINUE;
	}

	if (SQL_NumResults(Query) > 0)
	{
		log_amx( "[SourceBans] Database table found: %s_bans", g_dbConfig[DB_PREFIX] );
		HasLoadedBans = true;
	}
	else
	{
		log_amx( "[SourceBans] Could not find the table: %s_bans", g_dbConfig[DB_PREFIX] );
		log_amx( "[SourceBans] Bans won't be loaded" );
		HasLoadedBans = false;
	}
	return PLUGIN_CONTINUE;
}
//------------------
//	ShowGagsTable()
//------------------

public ShowGagsTable(FailState,Handle:Query,Error[],Errcode,Data[],DataSize)
{
	if(FailState==TQUERY_CONNECT_FAILED){
		log_amx( "[SourceBans] Could not connect to SQL database." );
		log_amx( "[SourceBans] Gags won't be loaded" );
		HasLoadedGags = false;
		return PLUGIN_CONTINUE;
	}
	else if (FailState == TQUERY_QUERY_FAILED)
	{
		log_amx( "[SourceBans] Query failed." );
		log_amx( "[SourceBans] Gags won't be loaded" );
		HasLoadedGags = false;
		return PLUGIN_CONTINUE;
	}

	if (Errcode)
	{
		log_amx( "[SourceBans] Error on query: %s", Error );
		log_amx( "[SourceBans] Gags won't be loaded" );
		HasLoadedGags = false;
		return PLUGIN_CONTINUE;
	}

	if (SQL_NumResults(Query) > 0)
	{
		log_amx( "[SourceBans] Database table found: %s_comms", g_dbConfig[DB_PREFIX] );
		HasLoadedGags = true;
	}
	else
	{
		log_amx( "[SourceBans] Could not find the table: %s_comms", g_dbConfig[DB_PREFIX] );
		log_amx( "[SourceBans] Gags won't be loaded" );
		HasLoadedGags = false;
	}
	return PLUGIN_CONTINUE;
}

//------------------
//	CheckGaggedPlayers()
//------------------

public CheckGaggedPlayers(FailState, Handle:Query, Error[], Errcode, Data[], DataSize)
{
	new id = Data[0];

	if (!HasLoadedGags)
	{
		set_task(1.5, "CheckIfGagged", id);
		server_print("Server has just started, checking Gags in 1.5 seconds instead...");
		return PLUGIN_CONTINUE;
	}

	if (FailState == TQUERY_CONNECT_FAILED)
		return set_fail_state("Could not connect to SQL database.");
	else if (FailState == TQUERY_QUERY_FAILED)
		return set_fail_state("Query failed.");

	if (Errcode)
		return log_amx("Error on query: %s",Error);

	if (!id)
		return PLUGIN_CONTINUE;

	if (SQL_NumResults(Query) >= 1)
	{
		new Name[32],
			TypeName[32];

		// Grab the type
		new type,
			sql_type;

		type = SQL_FieldNameToNum(Query, "type");

		while (SQL_MoreResults(Query))
		{
			sql_type = SQL_ReadResult(Query, type);
			SQL_NextRow(Query);
			
			//-----------------------
			if (sql_type == 1)
			{
				gag_voice[id] = true;
				TypeName = "muted";
			}
			if (sql_type == 2)
			{
				gag_chat[id] = true;
				TypeName = "gagged";
			}
			log_amx("client %d has type: %d", id, sql_type);
			//-----------------------
		}

		get_user_name(id, Name, 31);

		// Check if we got both chat and voice ban comm
		if( gag_chat[id] && gag_voice[id] )
			TypeName = "silenced";

		new formated_text[501];
		format(formated_text, 500, "[SourceBans] %s has joined and has been %s automatically.", Name, TypeName);
		PrintToAdmins(formated_text);
	}
	return PLUGIN_CONTINUE;
}

//------------------
//	CheckBannedPlayer()
//------------------

public CheckBannedPlayer(FailState, Handle:Query, Error[], Errcode, Data[], DataSize)
{
	new id = Data[0];

	if (!HasLoadedBans)
	{
		set_task(1.5, "CheckIfBanned", id);
		server_print("Server has just started, checking Bans in 1.5 seconds instead...");
		return PLUGIN_CONTINUE;
	}

	if (FailState == TQUERY_CONNECT_FAILED)
		return set_fail_state("Could not connect to SQL database.");
	else if (FailState == TQUERY_QUERY_FAILED)
		return set_fail_state("Query failed.");

	if (Errcode)
		return log_amx("Error on query: %s",Error);

	if (!id)
		return PLUGIN_CONTINUE;

	if (SQL_NumResults(Query) >= 1)
	{
		new Name[32],
			clientAuth[64],
			clientIp[64];

		get_user_name(id, Name, 31);
		get_user_authid(id, clientAuth, 63);
		get_user_ip(id, clientIp, 63);

		// Escape strings
		replace_all( Name, 2500, "`", "\`");
		replace_all( Name, 2500, "'", "\'");

		if (serverID == -1)
		{
			formatex(sql_cache, charsmax(sql_cache), "INSERT INTO %s_banlog (sid ,time ,name ,bid) VALUES  \
				((SELECT sid FROM %s_servers WHERE ip = '%s' AND port = '%s' LIMIT 0,1), UNIX_TIMESTAMP(), '%s', \
				(SELECT bid FROM %s_bans WHERE ((type = 0 AND authid REGEXP '^^STEAM_[0-9]:%s$') OR (type = 1 AND ip = '%s')) AND RemoveType IS NULL LIMIT 0,1))",
				g_dbConfig[DB_PREFIX], g_dbConfig[DB_PREFIX], ServerIP, ServerPort, Name, g_dbConfig[DB_PREFIX], clientAuth[8], clientIp);
		}
		else
		{
			formatex(sql_cache, charsmax(sql_cache), "INSERT INTO %s_banlog (sid ,time ,name ,bid) VALUES  \
				(%d, UNIX_TIMESTAMP(), '%s', \
				(SELECT bid FROM %s_bans WHERE ((type = 0 AND authid REGEXP '^^STEAM_[0-9]:%s$') OR (type = 1 AND ip = '%s')) AND RemoveType IS NULL LIMIT 0,1))",
				g_dbConfig[DB_PREFIX], serverID, Name, g_dbConfig[DB_PREFIX], clientAuth[8], clientIp);
		}

		SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);
		//server_cmd("banid 5 #%d", get_user_userid(id));
		server_cmd("kick #%d ^"You have been banned by this server, check %s for more info^"", get_user_userid(id), WebsiteAddress);
	}
	return PLUGIN_CONTINUE;
}

//------------------
//	QueryHandle()
//------------------

public QueryHandle( FailState, Handle:Query, Error[], Errcode, Data[], DataSize )
{
	// lots of error checking
	if ( FailState == TQUERY_CONNECT_FAILED ) {
		log_amx( "[Sourcebans] Could not connect to SQL database." );
		return set_fail_state("[SourceBans SQL] Could not connect to SQL database.");
	}
	else if ( FailState == TQUERY_QUERY_FAILED ) {
		new sql[1024];
		SQL_GetQueryString ( Query, sql, 1024 );
		log_amx( "[Sourcebans] SQL Query failed: %s", sql );
		return set_fail_state("[SourceBans SQL] SQL Query failed.");
	}

	if ( Errcode )
		return log_amx( "[Sourcebans] SQL Error on query: %s", Error );
	return PLUGIN_CONTINUE;
}

//------------------
//	PrintToAdmins()
//------------------

stock PrintToAdmins( Msg[] )
{
	new players[32],
		num,
		i;

	get_players(players, num);
	for (i=0; i<num; i++)
	{
		if (is_user_connected(players[i]))
		{
			if (!is_user_admin(players[i]))
				continue;
			client_print(players[i], print_chat, Msg);
		}
	}
}

//------------------
//	PrintToNonAdmin()
//------------------

stock PrintToNonAdmin( Msg[] )
{
	new players[32],
		num,
		i;

	get_players(players, num);
	for (i=0; i<num; i++)
	{
		if (is_user_connected(players[i]))
		{
			if (is_user_admin(players[i]))
				continue;
			client_print(players[i], print_chat, Msg);
		}
	}
}

//------------------
//	PrintToAll()
//------------------

stock PrintToAll( Msg[] )
{
	new players[32],
		num,
		i;

	get_players(players, num);
	for (i=0; i<num; i++)
	{
		if (is_user_connected(players[i]))
		{
			client_print(players[i], print_chat, Msg);
		}
	}
}