#include <sdktools>
#include <sdkhooks>

#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"

public Plugin myinfo =
{
	name = "RNGFix",
	author = "rio",
	description = "Fixes physics bugs in movement game modes",
	version = PLUGIN_VERSION,
	url = "https://github.com/cawnr912/rngfix-2"
}

// Engine constants, NOT settings (do not change)
#define LAND_HEIGHT 2.0 					// Maximum height above ground at which you can "land"
#define NON_JUMP_VELOCITY 140.0 			// Maximum Z velocity you are allowed to have and still land
#define MIN_STANDABLE_ZNRM 0.7				// Minimum surface normal Z component of a walkable surface
#define AIR_SPEED_CAP 30.0					// Air acceleration wishspeed cap when sv_air_max_wishspeed doesn't exist (CS:S)
#define DUCK_MIN_DUCKSPEED 1.5  			// Minimum duckspeed to start ducking
#define DEFAULT_JUMP_IMPULSE 301.99337741 	// sqrt(2 * 57.0 units * 800.0 u/s^2)

float g_vecMins[3];
float g_vecMaxsUnducked[3];
float g_vecMaxsDucked[3];
float g_flDuckDelta;

int g_iTick[MAXPLAYERS+1];
float g_flFrameTime[MAXPLAYERS+1];

bool g_bTouchingTrigger[MAXPLAYERS+1][2048];

// Targetnames known to exist, so trigger_teleport TouchPost doesn't scan every entity each tick.
// Only positive results are cached; a name is dropped when an entity with that name is destroyed.
StringMap g_smNameExists;

// Per-client counters for sm_rngfix_stats, so fixes can be checked from normal play without rngfix_debug.
enum
{
	STAT_COLLISION,			// pre-tick trace predicted a hit
	STAT_STARTSOLID,		// prediction ignored, trace started in solid
	STAT_UPHILL,
	STAT_EDGE,
	STAT_REWIND_SKIPPED,	// uphill/edge fix skipped, rewound origin not clear
	STAT_INCLINE,
	STAT_TRIGGERJUMP,
	STAT_STAIRS,
	STAT_TELEHOP,
	STAT_TELEHOP_SKIPPED,	// rngfix_telehop 2: contact came before the teleport trigger
	STAT_TELEHOP_UNKNOWN,	// rngfix_telehop 2: order couldn't be measured, restored anyway
	STAT_SUBTICK_APPLIED,	// time credit given back after an uphill/edge fix
	STAT_SUBTICK_DROPPED,	// time credit granted but not applied (no jump, blocked path, etc.)
	STAT_STAIRS_LEFTOVER,	// stair fix carried on the rest of the tick
	STAT_STAIRS_LEFTOVER_SKIPPED,	// stair fix leftover not applied (trigger on path, start solid)
	STAT_TELEPORT_LEFTOVER,	// travel after a teleport trigger's entry continued from the destination
	STAT_TELEPORT_LEFTOVER_SKIPPED,	// teleport leftover not granted (contact first, sequential, etc.)
	STAT_TELEPORT_LEFTOVER_DROPPED,	// teleport leftover granted but not applied (on ground, blocked path, etc.)
	STAT_EDGE_AVOIDED,		// subtick part 8: 1-bump said edge bug, 4-bump finds ground (no fix)
	STAT_EDGE_ADDED,		// subtick part 8: 1-bump found ground, 4-bump says edge bug (fix)
	STAT_COUNT
}

char g_szStatNames[STAT_COUNT][] =
{
	"Collisions predicted",
	"Predictions ignored (start solid)",
	"Uphill fixes",
	"Edge fixes",
	"Uphill/edge skipped (rewind blocked)",
	"Incline fixes",
	"Trigger jump fixes",
	"Stair fixes",
	"Telehop fixes",
	"Telehop skipped (contact first)",
	"Telehop order unknown (fallback)",
	"Subtick credits applied",
	"Subtick credits dropped",
	"Stair leftovers applied",
	"Stair leftovers skipped",
	"Teleport leftovers applied",
	"Teleport leftovers skipped",
	"Teleport leftovers dropped",
	"Edge fixes avoided by multi-bump",
	"Edge fixes added by multi-bump"
};

int g_iStats[MAXPLAYERS+1][STAT_COUNT];

// Sum of applied subtick credits, in ticks, for the averages shown by sm_rngfix_stats.
enum
{
	SUM_JUMP,
	SUM_STAIRS,
	SUM_TELEPORT,
	SUM_COUNT
}

float g_flTickSum[MAXPLAYERS+1][SUM_COUNT];

// Average rows of sm_rngfix_stats: label, and the stat that counts the applied credits.
char g_szSumNames[SUM_COUNT][] =
{
	"Subtick average credit (ticks)",
	"Stair leftover average (ticks)",
	"Teleport leftover average (ticks)"
};

int g_iSumStats[SUM_COUNT] = { STAT_SUBTICK_APPLIED, STAT_STAIRS_LEFTOVER, STAT_TELEPORT_LEFTOVER };

// Subtick time credit: the part of tick N after ground contact that an uphill/edge rewind discards.
// It is given back at the start of tick N+2 if the engine jumped on tick N+1.
// A teleport credit (subtick part 4) is the part of tick N after the hull entered a teleport trigger,
// given back at the start of tick N+1 from the destination.
float g_flSubtickCredit[MAXPLAYERS+1];		// seconds; 0.0 = no credit pending
int g_iSubtickKind[MAXPLAYERS+1];			// SUBTICK_JUMP or SUBTICK_TELEPORT
int g_iSubtickCreditTick[MAXPLAYERS+1];		// tick N, when the credit was granted
int g_iSubtickJumpTick[MAXPLAYERS+1];		// tick N+1, if the player left the ground on it
float g_flSubtickFrameTime[MAXPLAYERS+1];	// frame time on tick N, to detect lagged movement changes

// Server-wide counters for the name cache and trigger cleanup.
int g_iNameCacheHits;
int g_iNameScanFound;
int g_iNameScanMissed;
int g_iTouchFlagsCleared;

int g_iButtons[MAXPLAYERS+1];
float g_vVel[MAXPLAYERS+1][3];
float g_vAngles[MAXPLAYERS+1][3];
int g_iOldButtons[MAXPLAYERS+1];

int g_iLastTickPredicted[MAXPLAYERS+1];

float g_vPreCollisionVelocity[MAXPLAYERS+1][3];
float g_vLastBaseVelocity[MAXPLAYERS+1][3];
int g_iLastGroundEnt[MAXPLAYERS+1];
int g_iLastLandTick[MAXPLAYERS+1];
int g_iLastCollisionTick[MAXPLAYERS+1];
int g_iLastMapTeleportTick[MAXPLAYERS+1];
bool g_bMapTeleportedSequentialTicks[MAXPLAYERS+1];
float g_vCollisionPoint[MAXPLAYERS+1][3];
float g_vCollisionNormal[MAXPLAYERS+1][3];

// rngfix_telehop 2: the predicted move of this tick, used to find when the hull entered a teleport trigger.
float g_vPredStart[MAXPLAYERS+1][3];
float g_vPredEnd[MAXPLAYERS+1][3];
float g_vPredMins[MAXPLAYERS+1][3];
float g_vPredMaxs[MAXPLAYERS+1][3];
float g_flPredContactFraction[MAXPLAYERS+1];	// first hit along the predicted move, 1.0 if none
float g_flTeleportEntryFraction[MAXPLAYERS+1];	// earliest teleport trigger entry this tick, TELE_NOT_CROSSED if none
int g_iLastTriggerjumpTick[MAXPLAYERS+1];
int g_iLastRewindTick[MAXPLAYERS+1];	// last tick PreventCollision moved the player back

// "Stairs skip" debug lines repeat every tick while sliding along a ramp; print a reason only when it changes
// or after a tick without one.
int g_iLastStairsSkipTick[MAXPLAYERS+1];
int g_iLastStairsSkipReason[MAXPLAYERS+1];

#define TELE_NOT_CROSSED 2.0
#define TELEHOP_ORDERED 2

// rngfix_subtick bits
#define SUBTICK_JUMP		1	// uphill/edge fix time credit, given back after the next jump
#define SUBTICK_STAIRS		2	// stair fix carries on the rest of the tick along the step top
#define SUBTICK_TELEPORT	4	// travel after a teleport trigger's entry continues from the destination
#define SUBTICK_EDGE		8	// edge prediction slides through up to 4 planes

// SlideHull results; g_szSlideReason holds the text used in debug messages and drop reasons.
enum SlideResult
{
	Slide_OK,
	Slide_StartSolid,
	Slide_NoPlane,
	Slide_WouldLand,
	Slide_Crease,
	Slide_Blocked
}

char g_szSlideReason[][] =
{
	"",
	"path starts in solid",
	"path blocked (no plane)",
	"slide would land",
	"path blocked (crease)",
	"path blocked"
};

enum
{
	UPHILL_LOSS = -1,	// Force a jump, AND negatively affect speed as if a collision occurred (fix RNG not in player's favor)
	UPHILL_DEFAULT = 0, // Do nothing (retain RNG)
	UPHILL_NEUTRAL = 1	// Force a jump (respecting NON_JUMP_VELOCITY) (fix RNG in player's favor)
}

// Plugin settings
ConVar g_cvDownhill;
ConVar g_cvUphill;
ConVar g_cvEdge;
ConVar g_cvTriggerjump;
ConVar g_cvTelehop;
ConVar g_cvStairs;
ConVar g_cvUseOldSlopefixLogic;
ConVar g_cvSubtick;
ConVar g_cvSubtickParts;
ConVar g_cvBots;
ConVar g_cvDebug;

// Core physics ConVars
ConVar g_cvMaxVelocity;
ConVar g_cvGravity;
ConVar g_cvAirAccelerate;

// In CSS and CSGO but apparently not used in CSS
ConVar g_cvTimeBetweenDucks;
ConVar g_cvAirMaxWishspeed;

// CSGO-only
ConVar g_cvJumpImpulse;
ConVar g_cvAutoBunnyHopping;

Handle g_hPassesTriggerFilters;
Handle g_hProcessMovementHookPre;
Address g_IServerGameEnts;
Handle g_hMarkEntitiesAsTouching;

int g_iCMoveData_ForwardMove;
int g_iCMoveData_SideMove;
int g_iCMoveData_MaxSpeed;
int g_iCMoveData_Velocity;
int g_iCMoveData_Origin;
int g_iCMoveData_ViewAngles;
int g_iCMoveData_Buttons;
int g_iCMoveData_OldButtons;

bool g_bIsSurfMap;
ConVar g_cvSurfMap;

bool IsSurfMap()
{
	int mode = g_cvSurfMap.IntValue;
	if (mode == -1) return g_bIsSurfMap;
	return mode == 1;
}

bool g_bLateLoad;

int g_iLaserIndex;
int g_color1[] = {0, 100, 255, 255};
int g_color2[] = {0, 255, 0, 255};

void DebugMsg(int client, const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue) return;

	char output[1024];
	VFormat(output, sizeof(output), fmt, 3);
	PrintToConsole(client, "[%i] %s", g_iTick[client], output);
}

// Bots (e.g. replay bots that walk) follow recorded movement, so fixes would only make them drift.
bool SkipClient(int client)
{
	return !g_cvBots.BoolValue && IsFakeClient(client);
}

void DebugLaser(int client, const float p1[3], const float p2[3], float life, float width, const int color[4])
{
	if (g_cvDebug.IntValue < 2) return;

	TE_SetupBeamPoints(p2, p1, g_iLaserIndex, 0, 0, 0, life, width, width, 10, 0.0, color, 0);
	TE_SendToClient(client);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
   g_bLateLoad = late;
   return APLRes_Success;
}

public void OnPluginStart()
{
	EngineVersion engine = GetEngineVersion();

	if (engine != Engine_CSGO && engine != Engine_CSS)
	{
		SetFailState("Game is not supported");
	}

	g_vecMins 		  = view_as<float>({-16.0, -16.0, 0.0});
	g_vecMaxsUnducked = view_as<float>({16.0, 16.0, 0.0});
	g_vecMaxsDucked   = view_as<float>({16.0, 16.0, 0.0});

	g_vecMaxsUnducked[2] = engine == Engine_CSGO ? 72.0 : 62.0;
	g_vecMaxsDucked[2]   = engine == Engine_CSGO ? 54.0 : 45.0;

	g_flDuckDelta = (g_vecMaxsUnducked[2]-g_vecMaxsDucked[2]) / 2;

	CreateConVars();

	RegConsoleCmd("sm_rngfix_stats", Command_Stats, "Show how often each RNGFix fix has fired for you. Add 'reset' to zero the counters.");

	LoadGameData();

	if (g_bLateLoad)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client)) OnClientPutInServer(client);
		}

		char classname[64];
		for (int entity = MaxClients+1; entity < sizeof(g_bTouchingTrigger[]); entity++)
		{
			if (!IsValidEntity(entity)) continue;
			GetEntPropString(entity, Prop_Data, "m_iClassname", classname, sizeof(classname));
			HookTrigger(entity, classname);
		}
	}
}

// Plugin settings, then the engine ConVars the prediction reads.
void CreateConVars()
{
	g_cvDownhill 	= CreateConVar("rngfix_downhill", "1", "Enable downhill incline fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvUphill 		= CreateConVar("rngfix_uphill", "1", "Enable uphill incline fix. Set to -1 to normalize effects not in the player's favor (not recommended).", FCVAR_NOTIFY, true, -1.0, true, 1.0);
	g_cvEdge 		= CreateConVar("rngfix_edge", "1", "Enable edgebug fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTriggerjump = CreateConVar("rngfix_triggerjump", "1", "Enable trigger jump fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTelehop 	= CreateConVar("rngfix_telehop", "1", "Enable telehop fix. 2 = only restore speed if the teleport trigger was reached before the collision/landing.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	// The cvar outlives a plugin reload, and an older build created it with max 1, so raise the bound explicitly.
	g_cvTelehop.SetBounds(ConVarBound_Upper, true, 2.0);
	g_cvStairs		= CreateConVar("rngfix_stairs", "1", "Enable stair slide fix (surf only). You must have Movement Unlocker for sliding to work on CSGO.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvUseOldSlopefixLogic = CreateConVar("rngfix_useoldslopefixlogic", "0", "Old Slopefix had some logic errors that could cause double boosts. Enable this on a per-map basis to retain old behavior. (NOT RECOMMENDED)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSubtick = CreateConVar("rngfix_subtick", "1", "Subtick fixes: give back the part of a tick that fixes, stairs and teleports would otherwise lose. 0 = legacy (upstream timing), 1 = on.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// The cvar survives a plugin reload with the old build's bounds (fork.13 allowed 15), so set them explicitly.
	g_cvSubtick.SetBounds(ConVarBound_Upper, true, 1.0);
	g_cvSubtickParts = CreateConVar("rngfix_subtick_parts", "15", "Troubleshooting only: which subtick parts run when rngfix_subtick is 1, add together. 1 = uphill/edge time credit, 2 = stair leftover, 4 = teleport leftover, 8 = multi-plane edge prediction.", FCVAR_DONTRECORD, true, 0.0, true, 15.0);

	g_cvBots = CreateConVar("rngfix_bots", "0", "Apply fixes to bots (fake clients) too. 0 = skip bots, e.g. replay bots that walk instead of noclipping.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvSurfMap = CreateConVar("rngfix_surfmap", "-1", "Treat this map as a surf map (the stair fix only runs on surf maps). -1 = auto (name starts with surf_), 0 = no, 1 = yes. Set it in a map config to override.", FCVAR_NOTIFY, true, -1.0, true, 1.0);

	g_cvDebug = CreateConVar("rngfix_debug", "0", "1 = Enable debug messages. 2 = Enable debug messages and lasers.", _, true, 0.0, true, 2.0);

	AutoExecConfig();

	g_cvMaxVelocity   = FindConVar("sv_maxvelocity");
	g_cvGravity 	  = FindConVar("sv_gravity");
	g_cvAirAccelerate = FindConVar("sv_airaccelerate");

	if (g_cvMaxVelocity == null || g_cvGravity == null || g_cvAirAccelerate == null)
	{
		SetFailState("Could not find all ConVars");
	}

	// Not required
	g_cvTimeBetweenDucks = FindConVar("sv_timebetweenducks");
	g_cvJumpImpulse		 = FindConVar("sv_jump_impulse");
	g_cvAutoBunnyHopping = FindConVar("sv_autobunnyhopping");
	// CS:GO only; CS:S hard-codes 30.
	g_cvAirMaxWishspeed  = FindConVar("sv_air_max_wishspeed");
}

void LoadGameData()
{
	Handle gamedataConf = LoadGameConfigFile("rngfix.games");
	if (gamedataConf == null) SetFailState("Failed to load rngfix gamedata");

	// PassesTriggerFilters
	StartPrepSDKCall(SDKCall_Entity);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Virtual, "CBaseTrigger::PassesTriggerFilters"))
	{
		SetFailState("Failed to get CBaseTrigger::PassesTriggerFilters offset");
	}
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hPassesTriggerFilters = EndPrepSDKCall();

	if (g_hPassesTriggerFilters == null) SetFailState("Unable to prepare SDKCall for CBaseTrigger::PassesTriggerFilters");

	// CreateInterface
	// Thanks SlidyBat and ici
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Signature, "CreateInterface"))
	{
		SetFailState("Failed to get CreateInterface");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle CreateInterface = EndPrepSDKCall();

	if (CreateInterface == null) SetFailState("Unable to prepare SDKCall for CreateInterface");

	char interfaceName[64];

	// ProcessMovement
	if (!GameConfGetKeyValue(gamedataConf, "IGameMovement", interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get IGameMovement interface name");
	}
	Address IGameMovement = SDKCall(CreateInterface, interfaceName, 0);
	if (!IGameMovement)
	{
		SetFailState("Failed to get IGameMovement pointer");
	}

	int offset = GameConfGetOffset(gamedataConf, "ProcessMovement");
	if (offset == -1) SetFailState("Failed to get ProcessMovement offset");

	g_hProcessMovementHookPre = DHookCreate(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore, DHook_ProcessMovementPre);
	DHookAddParam(g_hProcessMovementHookPre, HookParamType_CBaseEntity);
	DHookAddParam(g_hProcessMovementHookPre, HookParamType_ObjectPtr);
	DHookRaw(g_hProcessMovementHookPre, false, IGameMovement);

	g_iCMoveData_ForwardMove = GetMoveDataOffset(gamedataConf, "CMoveData::m_flForwardMove");
	g_iCMoveData_SideMove    = GetMoveDataOffset(gamedataConf, "CMoveData::m_flSideMove");
	g_iCMoveData_MaxSpeed    = GetMoveDataOffset(gamedataConf, "CMoveData::m_flMaxSpeed");
	g_iCMoveData_Velocity    = GetMoveDataOffset(gamedataConf, "CMoveData::m_vecVelocity");
	g_iCMoveData_Origin      = GetMoveDataOffset(gamedataConf, "CMoveData::m_vecAbsOrigin");
	// These three were hard-coded before fork.12 and are the same in CS:S and CS:GO. Fall back to those
	// values so a server still on an older rngfix.games.txt keeps working.
	g_iCMoveData_ViewAngles = GetMoveDataOffset(gamedataConf, "CMoveData::m_vecViewAngles", 12);
	g_iCMoveData_Buttons    = GetMoveDataOffset(gamedataConf, "CMoveData::m_nButtons", 36);
	g_iCMoveData_OldButtons = GetMoveDataOffset(gamedataConf, "CMoveData::m_nOldButtons", 40);

	// MarkEntitiesAsTouching
	if (!GameConfGetKeyValue(gamedataConf, "IServerGameEnts", interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get IServerGameEnts interface name");
	}
	g_IServerGameEnts = SDKCall(CreateInterface, interfaceName, 0);
	if (!g_IServerGameEnts)
	{
		SetFailState("Failed to get IServerGameEnts pointer");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Virtual, "IServerGameEnts::MarkEntitiesAsTouching"))
	{
		SetFailState("Failed to get IServerGameEnts::MarkEntitiesAsTouching offset");
	}
	PrepSDKCall_AddParameter(SDKType_Edict, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Edict, SDKPass_Pointer);
	g_hMarkEntitiesAsTouching = EndPrepSDKCall();

	if (g_hMarkEntitiesAsTouching == null) SetFailState("Unable to prepare SDKCall for IServerGameEnts::MarkEntitiesAsTouching");

	delete CreateInterface;
	delete gamedataConf;
}

public void OnMapStart()
{
	g_iLaserIndex = PrecacheModel("materials/sprites/laserbeam.vmt", true);

	// The display name drops workshop/<id>/ so workshop surf maps match too.
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	g_bIsSurfMap = StrContains(map, "surf_", false) == 0;

	if (g_smNameExists == null) g_smNameExists = new StringMap();
	g_smNameExists.Clear();

	ResetServerStats();
}

void ResetServerStats()
{
	g_iNameCacheHits = g_iNameScanFound = g_iNameScanMissed = g_iTouchFlagsCleared = 0;
}

void ResetClientStats(int client)
{
	for (int i = 0; i < STAT_COUNT; i++) g_iStats[client][i] = 0;
	for (int i = 0; i < SUM_COUNT; i++) g_flTickSum[client][i] = 0.0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity >= sizeof(g_bTouchingTrigger[])) return;
	HookTrigger(entity, classname);
}

public void OnEntityDestroyed(int entity)
{
	// A cached "name exists" may no longer be true.
	if (g_smNameExists != null && IsValidEntity(entity))
	{
		char name[128];
		if (GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name)) != 0)
		{
			g_smNameExists.Remove(name);
		}
	}

	// Non-networked entities come through as references (negative), so bounds-check both ends.
	if (entity <= MaxClients || entity >= sizeof(g_bTouchingTrigger[])) return;

	// EndTouch isn't guaranteed when a trigger is removed, and the index can be reused by a new trigger.
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_bTouchingTrigger[client][entity]) g_iTouchFlagsCleared++;
		g_bTouchingTrigger[client][entity] = false;
	}
}

public Action Command_Stats(int client, int args)
{
	char arg[16];
	if (args > 0) GetCmdArg(1, arg, sizeof(arg));
	bool reset = StrEqual(arg, "reset", false);

	if (client > 0)
	{
		if (reset)
		{
			ResetClientStats(client);
		}
		else
		{
			ReplyToCommand(client, "[RNGFix %s] Your counts since connect/reset:", PLUGIN_VERSION);
			for (int i = 0; i < STAT_COUNT; i++)
			{
				ReplyToCommand(client, "  %-38s %i", g_szStatNames[i], g_iStats[client][i]);
			}

			for (int i = 0; i < SUM_COUNT; i++)
			{
				int applied = g_iStats[client][g_iSumStats[i]];
				ReplyToCommand(client, "  %-38s %.3f", g_szSumNames[i], applied > 0 ? g_flTickSum[client][i] / applied : 0.0);
			}
		}
	}

	if (reset)
	{
		ResetServerStats();
		ReplyToCommand(client, "[RNGFix] Counters reset.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "Server-wide since map start/reset:");
	ReplyToCommand(client, "  %-38s %i", "Teleport name cache hits", g_iNameCacheHits);
	ReplyToCommand(client, "  %-38s %i", "Teleport name full scans (found)", g_iNameScanFound);
	ReplyToCommand(client, "  %-38s %i", "Teleport name full scans (missing)", g_iNameScanMissed);
	ReplyToCommand(client, "  %-38s %i", "Touch flags cleared on destroy", g_iTouchFlagsCleared);

	return Plugin_Handled;
}

void HookTrigger(int entity, const char[] classname)
{
	if (StrContains(classname, "trigger_") != -1)
	{
		SDKHook(entity, SDKHook_StartTouchPost, Hook_TriggerStartTouch);
		SDKHook(entity, SDKHook_EndTouchPost, Hook_TriggerEndTouch);
	}

	if (StrContains(classname, "trigger_teleport") != -1)
	{
		SDKHook(entity, SDKHook_TouchPost, Hook_TriggerTeleportTouchPost);
	}
}

public void OnClientConnected(int client)
{
	g_iTick[client] = 0;
	for (int i = 0; i < sizeof(g_bTouchingTrigger[]); i++) g_bTouchingTrigger[client][i] = false;
	ResetClientStats(client);
	g_flSubtickCredit[client] = 0.0;

	// g_iTick restarts on every map change, so tick stamps from the last map would otherwise read as
	// "in the future" (a stale teleport tick dropped every jump credit as "teleported").
	g_iLastTickPredicted[client] = 0;
	g_iLastLandTick[client] = 0;
	g_iLastCollisionTick[client] = 0;
	g_iLastMapTeleportTick[client] = 0;
	g_iLastTriggerjumpTick[client] = 0;
	g_iLastRewindTick[client] = 0;
	g_iLastStairsSkipTick[client] = 0;
	g_iSubtickCreditTick[client] = 0;
	g_iSubtickJumpTick[client] = 0;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_GroundEntChangedPost, Hook_PlayerGroundEntChanged);
	SDKHook(client, SDKHook_PostThink, Hook_PlayerPostThink);
}

public Action Hook_TriggerStartTouch(int entity, int other)
{
	if (IsPlayer(other))
	{
		g_bTouchingTrigger[other][entity] = true;
		DebugMsg(other, "StartTouch %i", entity);
	}

	return Plugin_Continue;
}

// TODO Would be nice to have IServerTools::FindEntityByName / CGlobalEntityList::FindEntityByName
bool NameExists(const char[] targetname)
{
	// Assume special types exist
	if (targetname[0] == '!') return true;

	bool cached;
	if (g_smNameExists != null && g_smNameExists.GetValue(targetname, cached))
	{
		g_iNameCacheHits++;
		return true;
	}

	char targetname2[128];

	int max = GetMaxEntities();
	for (int entity = 1; entity < max; entity++)
	{
		if (!IsValidEntity(entity)) continue;
		if (GetEntPropString(entity, Prop_Data, "m_iName", targetname2, sizeof(targetname2)) == 0) continue;

		if (StrEqual(targetname, targetname2))
		{
			if (g_smNameExists != null) g_smNameExists.SetValue(targetname, true);
			g_iNameScanFound++;
			return true;
		}
	}

	g_iNameScanMissed++;
	return false;
}

public void Hook_TriggerTeleportTouchPost(int entity, int other)
{
	if (!IsPlayer(other)) return;

	if (!SDKCall(g_hPassesTriggerFilters, entity, other)) return;

	char targetstring[128];
	if (GetEntPropString(entity, Prop_Data, "m_target", targetstring, sizeof(targetstring)) == 0) return;

	if (!NameExists(targetstring)) return;

	if (g_iLastMapTeleportTick[other] == g_iTick[other]-1)
	{
		g_bMapTeleportedSequentialTicks[other] = true;
	}

	g_iLastMapTeleportTick[other] = g_iTick[other];

	DebugMsg(other, "Triggered teleport %i", entity);

	// For rngfix_telehop 2: sweep this tick's predicted move against the trigger to find when the hull entered it.
	// The ray was stored before the move, so it doesn't matter that the teleport has already moved the player.
	if (g_iLastTickPredicted[other] == g_iTick[other])
	{
		TR_ClipRayHullToEntity(g_vPredStart[other], g_vPredEnd[other], g_vPredMins[other], g_vPredMaxs[other], MASK_ALL, entity);

		float entry = TELE_NOT_CROSSED;
		if (TR_StartSolid()) entry = 0.0;
		else if (TR_DidHit()) entry = TR_GetFraction();

		if (entry < g_flTeleportEntryFraction[other]) g_flTeleportEntryFraction[other] = entry;
	}
}

public Action Hook_TriggerEndTouch(int entity, int other)
{
	if (IsPlayer(other))
	{
		g_bTouchingTrigger[other][entity] = false;
		DebugMsg(other, "EndTouch %i", entity);
	}
	return Plugin_Continue;
}

bool IsPlayer(int entity)
{
	return 1 <= entity <= MaxClients;
}

public bool PlayerFilter(int entity, int mask)
{
	return !IsPlayer(entity);
}

// Alive, walking and less than waist-deep in water: the only state the fixes care about.
bool IsWalking(int client)
{
	return IsPlayerAlive(client) && GetEntityMoveType(client) == MOVETYPE_WALK && !CheckWater(client);
}

// Local gravity (0 means 1) times sv_gravity.
float GetGravity(int client)
{
	float localGravity = GetEntPropFloat(client, Prop_Data, "m_flGravity");
	if (localGravity == 0.0) localGravity = 1.0;

	return localGravity * g_cvGravity.FloatValue;
}

void GetHull(int client, float mins[3], float maxs[3])
{
	GetEntPropVector(client, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(client, Prop_Data, "m_vecMaxs", maxs);
}

// Clips velocity against the plane into clipped; true if that gains horizontal speed (the downhill fix is better).
bool ClipGainsSpeed(const float velocity[3], const float nrm[3], float clipped[3])
{
	ClipVelocity(velocity, nrm, clipped);
	return clipped[0]*clipped[0] + clipped[1]*clipped[1] > velocity[0]*velocity[0] + velocity[1]*velocity[1];
}

// First trigger along the hull sweep that the client passes the filters of, or -1.
int FindTouchableTrigger(int client, const float start[3], const float end[3], const float mins[3], const float maxs[3])
{
	ArrayList triggers = new ArrayList();
	TR_EnumerateEntitiesHull(start, end, mins, maxs, true, AddTrigger, triggers);

	int found = -1;
	for (int i = 0; i < triggers.Length; i++)
	{
		int trigger = triggers.Get(i);
		if (SDKCall(g_hPassesTriggerFilters, trigger, client))
		{
			found = trigger;
			break;
		}
	}

	delete triggers;
	return found;
}

float GetJumpImpulse()
{
	return g_cvJumpImpulse != null ? g_cvJumpImpulse.FloatValue : DEFAULT_JUMP_IMPULSE;
}

bool IsDuckCoolingDown(int client)
{
	// TODO Is this stuff in MoveData?

	// Ducking is prevented if the last switch to a ducked state from an unducked state is sooner than sv_timebetweenducks ago.
	// Note: This cooldown is based on client's curtime (GetGameTime() in this context) and thus is unaffected by m_flLaggedMovementValue.
	if (g_cvTimeBetweenDucks != null && HasEntProp(client, Prop_Data, "m_flLastDuckTime"))
	{
		if (GetGameTime() - GetEntPropFloat(client, Prop_Data, "m_flLastDuckTime") < g_cvTimeBetweenDucks.FloatValue) return true;
	}

	// m_flDuckSpeed is decreased by 2.0 to a minimum of 0.0 every time the duck key is pressed OR released.
	// It recovers at a rate of 3.0 * m_flLaggedMovementValue per second and caps at 8.0.
	// Switching to a ducked state from an unducked state is prevented if it is less than 1.5.
	if (HasEntProp(client, Prop_Data, "m_flDuckSpeed"))
	{
		if (GetEntPropFloat(client, Prop_Data, "m_flDuckSpeed") < DUCK_MIN_DUCKSPEED) return true;
	}

	return false;
}

void Duck(int client, float origin[3], float mins[3], float maxs[3])
{
	bool ducking = GetEntityFlags(client) & FL_DUCKING != 0;

	bool nextDucking = ducking;

	if (g_iButtons[client] & IN_DUCK != 0 && !ducking)
	{
		if (!IsDuckCoolingDown(client))
		{
			origin[2] += g_flDuckDelta;
			nextDucking = true;
		}
	}
	else if (g_iButtons[client] & IN_DUCK == 0 && ducking)
	{
		origin[2] -= g_flDuckDelta;

		TR_TraceHullFilter(origin, origin, g_vecMins, g_vecMaxsUnducked, MASK_PLAYERSOLID, PlayerFilter);

		// Cannot unduck in air, not enough room
		if (TR_DidHit()) origin[2] += g_flDuckDelta;
		else nextDucking = false;
	}

	mins = g_vecMins;
	maxs = nextDucking ? g_vecMaxsDucked : g_vecMaxsUnducked;
}

bool CanJump(int client)
{
	if (g_iButtons[client] & IN_JUMP == 0) return false;
	if (g_iOldButtons[client] & IN_JUMP != 0 && !(g_cvAutoBunnyHopping != null && g_cvAutoBunnyHopping.BoolValue)) return false;

	return true;
}

void CheckJumpButton(int client, float velocity[3])
{
	// Skip dead and water checks since we already did them.

	// We need to check for ground somewhere so stick it here.
	if (GetEntityFlags(client) & FL_ONGROUND == 0) return;

	if (!CanJump(client)) return;

	// TODO Incorporate surfacedata jump factor

	// This conditional is why jumping while crouched jumps higher! Bad!
	if (GetEntProp(client, Prop_Data, "m_bDucking") != 0 || GetEntityFlags(client) & FL_DUCKING != 0)
	{
		velocity[2] = GetJumpImpulse();
	}
	else
	{
		velocity[2] += GetJumpImpulse();
	}

	// Jumping does an extra half tick of gravity! Bad!
	FinishGravity(client, velocity);
}

void AirAccelerate(int client, float velocity[3], Handle hParams)
{
	// This also includes the initial parts of AirMove()

	float fore[3], side[3];
	float wishvel[3], wishdir[3];

	GetAngleVectors(g_vAngles[client], fore, side, NULL_VECTOR);

	fore[2] = 0.0;
	side[2] = 0.0;
	NormalizeVector(fore, fore);
	NormalizeVector(side, side);

	for (int i = 0; i < 2; i++)	wishvel[i] = fore[i] * g_vVel[client][0] + side[i] * g_vVel[client][1];

	float wishspeed = NormalizeVector(wishvel, wishdir);
	float m_flMaxSpeed = DHookGetParamObjectPtrVar(hParams, 2, g_iCMoveData_MaxSpeed, ObjectValueType_Float);
	if (wishspeed > m_flMaxSpeed && m_flMaxSpeed != 0.0) wishspeed = m_flMaxSpeed;

	if (wishspeed)
	{
		float wishspd = wishspeed;
		float airSpeedCap = g_cvAirMaxWishspeed != null ? g_cvAirMaxWishspeed.FloatValue : AIR_SPEED_CAP;
		if (wishspd > airSpeedCap) wishspd = airSpeedCap;

		float currentspeed = GetVectorDotProduct(velocity, wishdir);
		float addspeed = wishspd - currentspeed;

		if (addspeed > 0)
		{
			float accelspeed = g_cvAirAccelerate.FloatValue * wishspeed * g_flFrameTime[client];
			if (accelspeed > addspeed) accelspeed = addspeed;

			for (int i = 0; i < 2; i++) velocity[i] += accelspeed * wishdir[i];
		}
	}
}

void CheckVelocity(float velocity[3])
{
	for (int i = 0; i < 3; i++)
	{
		if 		(velocity[i] >  g_cvMaxVelocity.FloatValue) velocity[i] =  g_cvMaxVelocity.FloatValue;
		else if (velocity[i] < -g_cvMaxVelocity.FloatValue) velocity[i] = -g_cvMaxVelocity.FloatValue;
	}
}

void StartGravity(int client, float velocity[3])
{
	velocity[2] -= GetGravity(client) * 0.5 * g_flFrameTime[client];

	float baseVelocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
	velocity[2] += baseVelocity[2] * g_flFrameTime[client];

	// baseVelocity[2] would get cleared here but we shouldn't do that since this is just a prediction.

	CheckVelocity(velocity);
}

void FinishGravity(int client, float velocity[3])
{
	velocity[2] -= GetGravity(client) * 0.5 * g_flFrameTime[client];

	CheckVelocity(velocity);
}

bool CheckWater(int client)
{
	// The cached water level is updated multiple times per tick, including after movement happens,
	// so we can just check the cached value here.
	return GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1;
}

// A missing key fails the plugin unless there is a fallback.
int GetMoveDataOffset(Handle gamedataConf, const char[] key, int fallback = -1)
{
	int offset = GameConfGetOffset(gamedataConf, key);
	if (offset != -1) return offset;

	if (fallback == -1) SetFailState("Failed to get %s", key);

	LogMessage("%s missing from rngfix.games.txt, using %d. Update the gamedata file.", key, fallback);
	return fallback;
}

// origin is the post-duck start of the move and duckShift the Z the engine's duck adds to the MoveData origin
// this tick (0 unless the player starts or stops ducking). Everything here works in post-duck space.
// On success counts the fix under stat and grants the jump subtick credit for the rest of the tick after fraction.
bool PreventCollision(int client, Handle hParams, const float origin[3], float duckShift, const float collisionPoint[3], const float velocity_tick[3], const float mins[3], const float maxs[3], int stat, float fraction)
{
	DebugLaser(client, origin, collisionPoint, 15.0, 0.5, g_color1);

	// Rewind part of a tick so at the end of this tick	we will end up close to the ground without colliding with it.
	// This effectively simulates a mid-tick jump (we lose part of a tick but its a miniscule trade-off).
	// This is also only an approximation of a partial tick rewind but it's good enough.
	float newOrigin[3];
	SubtractVectors(collisionPoint, velocity_tick, newOrigin);

	// Add a little space between us and the ground so we don't accidentally hit it anyway, maybe due to floating point error or something.
	// I don't know if this is necessary but I would rather be safe.
	newOrigin[2] += 0.1;

	// The rewound origin follows this tick's velocity backwards, which isn't always the path we came from
	// (e.g. after a teleport or a wall clip last tick). If it isn't clear, the engine's move would start
	// in solid and zero our velocity, so leave the tick alone instead.
	TR_TraceHullFilter(origin, newOrigin, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);
	if (TR_DidHit() || TR_StartSolid())
	{
		DebugMsg(client, "Fix skipped: rewound origin not clear");
		g_iStats[client][STAT_REWIND_SKIPPED]++;
		return false;
	}

	// Since the MoveData for this tick has already been filled and is about to be used, we need
	// to modify it directly instead of changing the player entity's actual position (such as with TeleportEntity).
	// MoveData is still pre-duck: the engine's duck will add duckShift again.
	float moveDataOrigin[3];
	moveDataOrigin = newOrigin;
	moveDataOrigin[2] -= duckShift;
	DHookSetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Origin, ObjectValueType_Vector, moveDataOrigin);
	if (duckShift != 0.0) DebugMsg(client, "Rewind on a duck tick: shift %.2f taken off the MoveData origin", duckShift);

	DebugLaser(client, origin, newOrigin, 15.0, 0.5, g_color2);

	float adjustment[3];
	SubtractVectors(newOrigin, origin, adjustment);
	DebugMsg(client, "Moved: %.2f %.2f %.2f", adjustment[0], adjustment[1], adjustment[2]);

	// No longer colliding this tick, clear our prediction flag
	g_iLastCollisionTick[client] = 0;
	g_iLastRewindTick[client] = g_iTick[client];

	g_iStats[client][stat]++;
	if (SubtickOn(SUBTICK_JUMP)) SetSubtickCredit(client, SUBTICK_JUMP, fraction);

	return true;
}

// Subtick time credit (rngfix_subtick).
// rngfix_subtick is the on/off switch; rngfix_subtick_parts (hidden, all on by default) lets a
// single part be turned off while troubleshooting.
bool SubtickOn(int part)
{
	return g_cvSubtick.BoolValue && (g_cvSubtickParts.IntValue & part) != 0;
}

// subtick part 4 (rngfix_subtick_parts). The engine moves the whole tick, then touches triggers and teleports the player
// to the destination, so the travel after the hull entered the trigger, (1 - entry fraction) of the tick,
// is lost. Grant it as a credit and carry it on from the destination at the start of the next tick.
// Called at the end of PostThink, after the telehop fix.
void GrantTeleportCredit(int client)
{
	if (!SubtickOn(SUBTICK_TELEPORT)) return;
	if (g_iLastMapTeleportTick[client] != g_iTick[client]) return;

	char reason[64];
	float entry = g_flTeleportEntryFraction[client];

	// The entry fraction comes from the predicted move, so we need one for this tick.
	if (g_iLastTickPredicted[client] != g_iTick[client]) strcopy(reason, sizeof(reason), "tick not predicted");
	// A teleport hub: the map meant to stop the player here.
	else if (g_bMapTeleportedSequentialTicks[client]) strcopy(reason, sizeof(reason), "sequential teleports");
	// The uphill/edge fix moved the start of the move, so the predicted ray is stale.
	else if (g_iLastRewindTick[client] == g_iTick[client]) strcopy(reason, sizeof(reason), "rewound this tick");
	else if (g_iLastTriggerjumpTick[client] == g_iTick[client]) strcopy(reason, sizeof(reason), "trigger jump fix");
	else if (entry == TELE_NOT_CROSSED) strcopy(reason, sizeof(reason), "trigger not on path");
	// Already overlapping at the start of the tick should have teleported us last tick, so don't trust it.
	else if (entry <= 0.0) strcopy(reason, sizeof(reason), "inside trigger at tick start");
	// After a collision the real path leaves the predicted ray, so the entry time is unknown.
	else if (entry > g_flPredContactFraction[client] + 0.001) strcopy(reason, sizeof(reason), "contact first");

	if (reason[0] != '\0')
	{
		DebugMsg(client, "Teleport subtick skipped: %s", reason);
		g_iStats[client][STAT_TELEPORT_LEFTOVER_SKIPPED]++;
		return;
	}

	SetSubtickCredit(client, SUBTICK_TELEPORT, entry);
}

// Jump credit (granted by PreventCollision): it makes tick N end at the contact point, so the part of the
// tick after contact, (1 - fraction) of it, is lost: the player is that far behind a jump made at the moment
// of contact. The engine still lands them at the end of N and jumps them on N+1 (events, stamina, sounds,
// timers all stay engine-driven). At the start of N+2 we move them forward along their airborne path by the
// lost time. If anything doesn't line up, the credit is dropped and the tick plays out as before.
void SetSubtickCredit(int client, int kind, float fraction)
{
	DropSubtickCredit(client, "replaced by a newer credit");

	float credit = (1.0 - fraction) * g_flFrameTime[client];
	if (credit <= 0.0) return;

	g_flSubtickCredit[client] = credit;
	g_iSubtickKind[client] = kind;
	g_iSubtickCreditTick[client] = g_iTick[client];
	g_iSubtickJumpTick[client] = 0;
	g_flSubtickFrameTime[client] = g_flFrameTime[client];

	DebugMsg(client, "Subtick credit%s: %.3f tick", kind == SUBTICK_TELEPORT ? " (teleport)" : "", 1.0 - fraction);
}

void DropSubtickCredit(int client, const char[] reason)
{
	if (g_flSubtickCredit[client] <= 0.0) return;

	g_flSubtickCredit[client] = 0.0;
	bool teleport = g_iSubtickKind[client] == SUBTICK_TELEPORT;
	g_iStats[client][teleport ? STAT_TELEPORT_LEFTOVER_DROPPED : STAT_SUBTICK_DROPPED]++;
	DebugMsg(client, "Subtick dropped%s: %s", teleport ? " (teleport)" : "", reason);
}

void ApplySubtickCredit(int client, Handle hParams)
{
	if (g_flSubtickCredit[client] <= 0.0) return;

	int kind = g_iSubtickKind[client];
	bool teleport = kind == SUBTICK_TELEPORT;

	// A jump credit waits for tick N+1 (the engine's jump tick) to finish; a teleport credit applies on N+1.
	int due = g_iSubtickCreditTick[client] + (teleport ? 1 : 2);
	if (g_iTick[client] < due) return;

	if (g_iTick[client] != due) { DropSubtickCredit(client, "expired"); return; }
	if (!SubtickOn(kind)) { DropSubtickCredit(client, "disabled"); return; }
	if (!teleport)
	{
		if (g_iSubtickJumpTick[client] != g_iSubtickCreditTick[client] + 1) { DropSubtickCredit(client, "no jump after landing"); return; }
		if (g_iLastMapTeleportTick[client] >= g_iSubtickCreditTick[client]) { DropSubtickCredit(client, "teleported"); return; }
	}
	if (!IsWalking(client)) { DropSubtickCredit(client, "not walking"); return; }
	if (GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") != -1) { DropSubtickCredit(client, "on ground"); return; }
	if (FloatAbs(g_flFrameTime[client] - g_flSubtickFrameTime[client]) > 0.00001) { DropSubtickCredit(client, "lagged movement changed"); return; }

	float baseVelocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
	if (GetVectorLength(baseVelocity) != 0.0) { DropSubtickCredit(client, "base velocity"); return; }

	float credit = g_flSubtickCredit[client];

	float origin[3], velocity[3];
	DHookGetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Origin, ObjectValueType_Vector, origin);
	DHookGetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Velocity, ObjectValueType_Vector, velocity);

	// A destination that zeroes velocity is the map stopping the player on purpose.
	if (teleport && GetVectorLength(velocity) < 1.0) { DropSubtickCredit(client, "stopped by teleport"); return; }

	float gravity = GetGravity(client);

	// Ballistic step over the credited time (no air acceleration in this version).
	float move[3];
	for (int i = 0; i < 3; i++) move[i] = velocity[i] * credit;
	move[2] -= 0.5 * gravity * credit * credit;

	velocity[2] -= gravity * credit;

	float mins[3], maxs[3];
	GetHull(client, mins, maxs);

	// Slide along anything in the way; drop instead if the slide would land the player or the path stays blocked.
	float newOrigin[3];
	newOrigin = origin;

	SlideResult slide = SlideHull(client, newOrigin, move, velocity, mins, maxs, true);
	if (slide != Slide_OK)
	{
		DropSubtickCredit(client, g_szSlideReason[slide]);
		return;
	}

	CheckVelocity(velocity);

	DHookSetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Origin, ObjectValueType_Vector, newOrigin);
	DHookSetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Velocity, ObjectValueType_Vector, velocity);

	g_flSubtickCredit[client] = 0.0;
	int sum = teleport ? SUM_TELEPORT : SUM_JUMP;
	g_iStats[client][g_iSumStats[sum]]++;
	g_flTickSum[client][sum] += credit / g_flSubtickFrameTime[client];

	DebugLaser(client, origin, newOrigin, 15.0, 0.5, g_color2);

	float adjustment[3];
	SubtractVectors(newOrigin, origin, adjustment);
	DebugMsg(client, "Subtick applied%s: moved %.2f %.2f %.2f", teleport ? " (teleport)" : "", adjustment[0], adjustment[1], adjustment[2]);
}

// Move a hull along `move` like the engine's TryPlayerMove: on each hit, clip the remaining move and
// the velocity against the plane and continue, up to 4 planes. On success `origin` is the end position
// and `velocity` is clipped by every plane hit. Fails if the path starts in solid, stays blocked,
// runs into a crease, or (with stopOnLand) a slide would land the player.
SlideResult SlideHull(int client, float origin[3], float move[3], float velocity[3], const float mins[3], const float maxs[3], bool stopOnLand)
{
	float end[3], nrm[3], remaining[3];
	float planes[4][3];
	int numPlanes = 0;

	for (int bump = 0; bump < 4; bump++)
	{
		AddVectors(origin, move, end);
		TR_TraceHullFilter(origin, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);
		if (TR_StartSolid()) return Slide_StartSolid;

		TR_GetEndPosition(origin);
		if (!TR_DidHit()) return Slide_OK;

		float fraction = TR_GetFraction();
		TR_GetPlaneNormal(null, nrm);
		if (nrm[0] == 0.0 && nrm[1] == 0.0 && nrm[2] == 0.0) return Slide_NoPlane;

		ClipVelocity(velocity, nrm, velocity);
		if (stopOnLand && nrm[2] >= MIN_STANDABLE_ZNRM && velocity[2] <= NON_JUMP_VELOCITY) return Slide_WouldLand;

		ScaleVector(move, 1.0 - fraction);
		ClipVelocity(move, nrm, remaining);
		move = remaining;

		// A crease: the clipped move heads back into an earlier plane. The engine would
		// slide along the crease line; we don't bother for a sub-tick move.
		for (int p = 0; p < numPlanes; p++)
		{
			if (GetVectorDotProduct(move, planes[p]) < -0.001) return Slide_Crease;
		}
		planes[numPlanes++] = nrm;

		DebugMsg(client, "Subtick slide: plane %.3f %.3f %.3f at fraction %.3f", nrm[0], nrm[1], nrm[2], fraction);
	}

	return Slide_Blocked;
}

// subtick part 2 (rngfix_subtick_parts). The stair fix puts the player 1 unit past the wall contact point, so the rest of
// the tick's horizontal travel, (1 - contact fraction) of it, is lost. Carry it on along the step top,
// stopping at whatever is in the way (the next step face is handled by next tick's stair fix).
// pos is updated in place; if anything looks unsafe it's left alone and the plain fix applies.
void StairsLeftover(int client, float pos[3], const float dir[3], const float mins[3], const float maxs[3])
{
	float speed = SquareRoot(g_vPreCollisionVelocity[client][0]*g_vPreCollisionVelocity[client][0]
		+ g_vPreCollisionVelocity[client][1]*g_vPreCollisionVelocity[client][1]);
	float leftover = 1.0 - g_flPredContactFraction[client];

	// The fix already moved us 1 unit forward.
	float distance = speed * leftover * g_flFrameTime[client] - 1.0;
	if (distance <= 0.0) return;

	float end[3];
	for (int i = 0; i < 3; i++) end[i] = pos[i] + dir[i]*distance;

	TR_TraceHullFilter(pos, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);
	if (TR_StartSolid())
	{
		DebugMsg(client, "Stairs subtick skipped: path starts in solid");
		g_iStats[client][STAT_STAIRS_LEFTOVER_SKIPPED]++;
		return;
	}

	float stop[3];
	TR_GetEndPosition(stop);

	char hit[48];
	if (TR_DidHit())
	{
		float nrm[3];
		TR_GetPlaneNormal(null, nrm);
		FormatEx(hit, sizeof(hit), ", stopped by %.3f %.3f %.3f", nrm[0], nrm[1], nrm[2]);
	}

	// Same caution as the ground check in DoStairsFix: don't skip past a trigger the player would touch.
	int trigger = FindTouchableTrigger(client, pos, stop, mins, maxs);
	if (trigger != -1)
	{
		DebugMsg(client, "Stairs subtick skipped: trigger %i on the path", trigger);
		g_iStats[client][STAT_STAIRS_LEFTOVER_SKIPPED]++;
		return;
	}

	DebugLaser(client, pos, stop, 15.0, 0.5, g_color2);
	DebugMsg(client, "Stairs subtick: +%.2f units (%.3f tick)%s", GetVectorDistance(pos, stop), leftover, hit);

	pos = stop;
	g_iStats[client][STAT_STAIRS_LEFTOVER]++;
	g_flTickSum[client][SUM_STAIRS] += leftover;
}

void ClipVelocity(const float velocity[3], const float nrm[3], float out[3])
{
	float backoff = GetVectorDotProduct(velocity, nrm);

	for (int i = 0; i < 3; i++)
	{
		out[i] = velocity[i] - nrm[i]*backoff;
	}

	// The adjust step only matters with overbounce which doesnt apply to walkable surfaces.
}

void SetVelocity(int client, float velocity[3], bool dontUseTeleportEntity = false)
{
	// Pull out basevelocity from desired true velocity
	// Use the pre-tick basevelocity because that is what influenced this tick's movement and the desired new velocity.
	SubtractVectors(velocity, g_vLastBaseVelocity[client], velocity);

	if (dontUseTeleportEntity && GetEntPropEnt(client, Prop_Data, "m_hMoveParent") == -1)
	{
		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
	}
	else
	{
		float baseVelocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);

		// TeleportEntity with non-null velocity wipes out basevelocity, so restore it after.
		// Since we didn't change position, nothing should change regarding influences on basevelocity.
		SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
	}
}

public MRESReturn DHook_ProcessMovementPre(Handle hParams)
{
	int client = DHookGetParam(hParams, 1);

	g_iTick[client]++;
	g_flFrameTime[client] = GetTickInterval() * GetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue");
	g_bMapTeleportedSequentialTicks[client] = false;
	g_flTeleportEntryFraction[client] = TELE_NOT_CROSSED;

	if (SkipClient(client))
	{
		// Covers rngfix_bots being turned off while a credit is held.
		DropSubtickCredit(client, "bot");
		return MRES_Ignored;
	}

	// Before prediction, so this tick is predicted from the corrected state.
	ApplySubtickCredit(client, hParams);

	// If we are actually not doing ANY of the fixes that rely on pre-tick collision prediction, skip all this.
	if (!g_cvUphill.BoolValue && !g_cvEdge.BoolValue && !g_cvStairs.BoolValue && !g_cvTelehop.BoolValue && !g_cvDownhill.BoolValue)
	{
		return MRES_Ignored;
	}

	RunPreTickChecks(client, hParams);

	return MRES_Ignored;
}

void RunPreTickChecks(int client, Handle hParams)
{
	// Recreate enough of CGameMovement::ProcessMovement to predict if fixes are needed.
	// We only really care about a limited set of scenarios (less than waist-deep in water, MOVETYPE_WALK, air movement).

	if (!IsWalking(client)) return;

	g_iLastGroundEnt[client] = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");

	// If we are definitely staying on the ground this tick, don't predict it.
	if (g_iLastGroundEnt[client] != -1 && !CanJump(client)) return;

	g_iLastTickPredicted[client] = g_iTick[client];

	g_iButtons[client] = DHookGetParamObjectPtrVar(hParams, 2, g_iCMoveData_Buttons, ObjectValueType_Int);
	g_iOldButtons[client] = DHookGetParamObjectPtrVar(hParams, 2, g_iCMoveData_OldButtons, ObjectValueType_Int);
	g_vVel[client][0] = DHookGetParamObjectPtrVar(hParams, 2, g_iCMoveData_ForwardMove, ObjectValueType_Float);
	g_vVel[client][1] = DHookGetParamObjectPtrVar(hParams, 2, g_iCMoveData_SideMove, ObjectValueType_Float);
	g_vVel[client][2] = 0.0;
	DHookGetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_ViewAngles, ObjectValueType_Vector, g_vAngles[client]);

	float velocity[3];
	DHookGetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Velocity, ObjectValueType_Vector, velocity);

	float baseVelocity[3];
	// basevelocity is not stored in MoveData
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);

	float origin[3];
	DHookGetParamObjectPtrVarVector(hParams, 2, g_iCMoveData_Origin, ObjectValueType_Vector, origin);

	float nextOrigin[3], mins[3], maxs[3];

	nextOrigin = origin;

	// These roughly replicate the behavior of their equivalent CGameMovement functions.

	Duck(client, nextOrigin, mins, maxs);

	// The engine's duck runs inside ProcessMovement, after this hook, so MoveData still holds the pre-duck origin.
	// The move itself starts from the post-duck origin; trace from there, and take the shift back off before
	// writing an origin into MoveData (see PreventCollision).
	float duckedOrigin[3];
	duckedOrigin = nextOrigin;
	float duckShift = duckedOrigin[2] - origin[2];

	StartGravity(client, velocity);

	CheckJumpButton(client, velocity);

	CheckVelocity(velocity);

	AirAccelerate(client, velocity, hParams);

	// StartGravity dealt with Z basevelocity.
	baseVelocity[2] = 0.0;
	g_vLastBaseVelocity[client] = baseVelocity;
	AddVectors(velocity, baseVelocity, velocity);

	// Store this for later in case we need to undo the effects of a collision.
	g_vPreCollisionVelocity[client] = velocity;

	// This is basically where TryPlayerMove happens.
	// We don't really care about anything after TryPlayerMove either.

	float velocity_tick[3];
	velocity_tick = velocity;
	ScaleVector(velocity_tick, g_flFrameTime[client]);

	AddVectors(nextOrigin, velocity_tick, nextOrigin);

	// Check if we will hit something this tick.
	TR_TraceHullFilter(duckedOrigin, nextOrigin, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	// Later traces overwrite this, and the subtick credit needs it.
	float fraction = TR_GetFraction();

	// Kept for rngfix_telehop 2 (see Hook_TriggerTeleportTouchPost and DoTelehopFix).
	g_vPredStart[client] = duckedOrigin;
	g_vPredEnd[client] = nextOrigin;
	g_vPredMins[client] = mins;
	g_vPredMaxs[client] = maxs;
	g_flPredContactFraction[client] = TR_DidHit() ? fraction : 1.0;

	// A trace that starts inside solid has no usable plane (the normal comes back as 0 0 0).
	// That means our prediction doesn't match the real player (e.g. a hull mismatch), so don't act on it.
	bool startSolid = TR_StartSolid() || TR_AllSolid();
	if (TR_DidHit() && startSolid)
	{
		DebugMsg(client, "Prediction ignored: trace started in solid");
		g_iStats[client][STAT_STARTSOLID]++;
	}

	if (!TR_DidHit() || startSolid) return;

	float nrm[3];
	TR_GetPlaneNormal(null, nrm);

	if (g_iLastCollisionTick[client] < g_iTick[client]-1)
	{
		DebugMsg(client, "Collision predicted! (normal: %.3f %.3f %.3f)", nrm[0], nrm[1], nrm[2]);
		g_iStats[client][STAT_COLLISION]++;
	}

	float collisionPoint[3];
	TR_GetEndPosition(collisionPoint);

	// Store this result for post-tick fixes.
	g_iLastCollisionTick[client] = g_iTick[client];
	g_vCollisionPoint[client] = collisionPoint;
	g_vCollisionNormal[client] = nrm;

	// If we are moving up too fast, we can't land anyway so these fixes aren't needed.
	if (velocity[2] > NON_JUMP_VELOCITY)
	{
		// Only report walkable surfaces, otherwise surf ramps print this every tick.
		if (nrm[2] >= MIN_STANDABLE_ZNRM) DebugMsg(client, "Uphill skip: rising too fast (z-vel %.2f)", velocity[2]);
		return;
	}

	// Landing also requires a walkable surface.
	// This will give false negatives if the surface initially collided
	// is too steep but the final one isn't (rare and unlikely to matter).
	if (nrm[2] < MIN_STANDABLE_ZNRM) return;

	// Check uphill incline fix first since it's more common and faster.
	// Make sure it's not flat, that we are actually going uphill (X/Y dot product < 0.0),
	// and that this isn't a case where it's actually more beneficial to do the downhill fix.
	float newVelocity[3];
	if (g_cvUphill.IntValue == UPHILL_NEUTRAL && nrm[2] < 1.0 && nrm[0]*velocity[0] + nrm[1]*velocity[1] < 0.0
		&& !(g_cvDownhill.BoolValue && ClipGainsSpeed(velocity, nrm, newVelocity)))
	{
		DebugMsg(client, "DO FIX: Uphill Incline");
		PreventCollision(client, hParams, duckedOrigin, duckShift, collisionPoint, velocity_tick, mins, maxs, STAT_UPHILL, fraction);

		// This naturally prevents any edge bugs so we can skip the edge fix.
		// If the rewind was rejected, the edge fix would make the same rewind, so skip it either way.
		return;
	}

	if (!g_cvEdge.BoolValue) return;

	float tickEnd[3];
	if (!PredictEdgeBug(client, velocity, nrm, collisionPoint, fraction, velocity_tick, mins, maxs, tickEnd)) return;

	DebugMsg(client, "DO FIX: Edge Bug");
	DebugLaser(client, collisionPoint, tickEnd, 15.0, 0.5, g_color1);

	PreventCollision(client, hParams, duckedOrigin, duckShift, collisionPoint, velocity_tick, mins, maxs, STAT_EDGE, fraction);
}

// Edge fix: estimate where the player will be at the end of the tick after colliding, and return true
// if there is no ground to land on there (an edge bug). tickEnd is set to the estimated end position.
bool PredictEdgeBug(int client, const float velocity[3], const float nrm[3], const float collisionPoint[3], float fraction, const float velocity_tick[3], const float mins[3], const float maxs[3], float tickEnd[3])
{
	// Do a rough estimate of where we will be at the end of the tick after colliding.
	// This method assumes no more collisions will take place after the first.
	// There are some very extreme circumstances where this will give false positives (unlikely to come into play).

	float fraction_left = 1.0 - fraction;

	float clipped[3];
	ClipVelocity(velocity, nrm, clipped);

	if (nrm[2] == 1.0)
	{
		// If the ground is level, all that changes is Z velocity becomes zero.
		tickEnd[0] = collisionPoint[0] + velocity_tick[0]*fraction_left;
		tickEnd[1] = collisionPoint[1] + velocity_tick[1]*fraction_left;
		tickEnd[2] = collisionPoint[2];
	}
	else
	{
		// This would be an "edge bug" (slide without landing at the end of the tick)
		// 100% of the time due to the Z velocity restriction.
		if (clipped[2] > NON_JUMP_VELOCITY) return false;

		float velocity2[3];
		velocity2 = clipped;
		ScaleVector(velocity2, g_flFrameTime[client]*fraction_left);
		AddVectors(collisionPoint, velocity2, tickEnd);
	}

	// Check if there's something close enough to land on below the player at the end of this tick.
	bool canLand = CanLandBelow(tickEnd, mins, maxs);

	// subtick part 8 (rngfix_subtick_parts): the estimate above ignores anything hit after the first plane (a ramp
	// corner, a wall next to the edge). Slide the rest of the tick through up to 4 planes instead.
	if (SubtickOn(SUBTICK_EDGE))
	{
		float velocity3[3], move[3], tickEnd4[3];
		velocity3 = clipped;
		move = clipped;
		ScaleVector(move, g_flFrameTime[client]*fraction_left);
		tickEnd4 = collisionPoint;

		SlideResult slide = SlideHull(client, tickEnd4, move, velocity3, mins, maxs, false);
		bool slid = slide == Slide_OK;

		// A path that starts in solid leaves tickEnd4 at the collision point; keep the 1-bump result then.
		// Any other failure (blocked, crease) leaves it where the player stops, which is still the right place to look.
		if (slide == Slide_StartSolid)
		{
			DebugMsg(client, "Edge predict: 4-bump failed (%s), using 1-bump", g_szSlideReason[slide]);
		}
		else if (velocity3[2] > NON_JUMP_VELOCITY)
		{
			// The slide ends going up (e.g. up a kicker ramp past the ledge), so the player can't land
			// this tick whatever is below. Same as the 1-bump branch above: no fix.
			DebugMsg(client, "Edge predict: 4-bump ends rising (z-vel %.1f), no fix%s", velocity3[2], canLand ? "" : " (1-bump said edge bug)");
			if (!canLand) g_iStats[client][STAT_EDGE_AVOIDED]++;
			return false;
		}
		else
		{
			bool canLand4 = CanLandBelow(tickEnd4, mins, maxs);
			if (canLand4 != canLand)
			{
				DebugMsg(client, "Edge predict: 1-bump %s, 4-bump %s%s", canLand ? "lands" : "edge bug", canLand4 ? "lands" : "edge bug", slid ? "" : " (path blocked)");
				g_iStats[client][canLand4 ? STAT_EDGE_AVOIDED : STAT_EDGE_ADDED]++;
			}
			canLand = canLand4;
			tickEnd = tickEnd4;
		}
	}

	return !canLand;
}

public void Hook_PlayerGroundEntChanged(int client)
{
	// We cannot get the new ground entity at this point,
	// but if the previous value was -1, it must be something else now, so we landed.
	if (GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") == -1)
	{
		g_iLastLandTick[client] = g_iTick[client];
		DebugMsg(client, "Landed");
	}
}

bool DoTriggerjumpFix(int client, const float landingPoint[3], const float landingMins[3], const float landingMaxs[3])
{
	if (!g_cvTriggerjump.BoolValue) return false;

	// It's possible to land above a trigger but also in another trigger_teleport, have the teleport move you to
	// another location, and then the trigger jumping fix wouldn't fire the other trigger you technically landed above,
	// but I can't imagine a mapper would ever actually stack triggers like that.

	float origin[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

	float landingMaxsBelow[3];
	landingMaxsBelow[0] = landingMaxs[0];
	landingMaxsBelow[1] = landingMaxs[1];
	landingMaxsBelow[2] = origin[2] - landingPoint[2];

	ArrayList triggers = new ArrayList();

	// Find triggers that are between us and the ground (using the bounding box quadrant we landed with if applicable).
	TR_EnumerateEntitiesHull(landingPoint, landingPoint, landingMins, landingMaxsBelow, true, AddTrigger, triggers);

	bool didSomething = false;

	for (int i = 0; i < triggers.Length; i++)
	{
		int trigger = triggers.Get(i);

		// MarkEntitiesAsTouching always fires the Touch function even if it was already fired this tick.
		// In case that could cause side-effects, manually keep track of triggers we are actually touching
		// and don't re-touch them.
		if (g_bTouchingTrigger[client][trigger]) continue;

		DebugMsg(client, "DO FIX: Trigger Jumping (entity %i)", trigger);

		SDKCall(g_hMarkEntitiesAsTouching, g_IServerGameEnts, client, trigger);
		g_iStats[client][STAT_TRIGGERJUMP]++;
		g_iLastTriggerjumpTick[client] = g_iTick[client];
		didSomething = true;
	}

	delete triggers;

	return didSomething;
}

// True if this stair skip reason wasn't already printed on the previous tick.
bool StairsSkipIsNew(int client, int reason)
{
	bool repeat = g_iLastStairsSkipTick[client] == g_iTick[client] - 1 && g_iLastStairsSkipReason[client] == reason;
	g_iLastStairsSkipTick[client] = g_iTick[client];
	g_iLastStairsSkipReason[client] = reason;
	return !repeat;
}

bool DoStairsFix(int client)
{
	if (!g_cvStairs.BoolValue) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	// This fix has undesirable side-effects on bhop. It is also very unlikely to help on bhop.
	if (!IsSurfMap()) return false;

	// Let teleports take precedence (including teleports activated by the trigger jumping fix).
	if (g_iLastMapTeleportTick[client] == g_iTick[client]) return false;

	bool collidedThisTick = g_iLastCollisionTick[client] == g_iTick[client];

	// If moving upward, the player would never be able to slide up with any current position.
	if (g_vPreCollisionVelocity[client][2] > 0.0)
	{
		if (collidedThisTick && StairsSkipIsNew(client, 1)) DebugMsg(client, "Stairs skip: moving up (z-vel %.2f)", g_vPreCollisionVelocity[client][2]);
		return false;
	}

	if (collidedThisTick && g_vCollisionNormal[client][2] != 0.0 && StairsSkipIsNew(client, 2))
	{
		DebugMsg(client, "Stairs skip: face not vertical (z-normal %.4f)", g_vCollisionNormal[client][2]);
	}

	// Stair step faces don't necessarily have to be completely vertical, but, if they are not,
	// sliding up them at high speed -- or even just walking up -- usually doesn't work.
	// Plus, it's really unlikely that there are actual stairs shaped like that.
	// Require a real horizontal normal: a zero vector also has Z == 0 but is not a wall.
	if (!collidedThisTick || g_vCollisionNormal[client][2] != 0.0) return false;
	if (g_vCollisionNormal[client][0] == 0.0 && g_vCollisionNormal[client][1] == 0.0) return false;

	// Do this first and stop if we are moving slowly (less than 1 unit per tick).
	float velocity_dir[3];
	velocity_dir = g_vPreCollisionVelocity[client];
	velocity_dir[2] = 0.0;
	if (NormalizeVector(velocity_dir, velocity_dir) * g_flFrameTime[client] < 1.0)
	{
		DebugMsg(client, "Stairs skip: too slow");
		return false;
	}

	float mins[3], maxs[3];
	GetHull(client, mins, maxs);

	// We seem to have collided with a "wall", now figure out if it's a stair step.

	// Look for ground below us
	float stepsize = GetEntPropFloat(client, Prop_Data, "m_flStepSize");

	float end[3];
	end = g_vCollisionPoint[client];
	end[2] -= stepsize;

	TR_TraceHullFilter(g_vCollisionPoint[client], end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (!TR_DidHit())
	{
		DebugMsg(client, "Stairs skip: no ground within step size (%.1f) below contact", stepsize);
		return false;
	}

	float nrm[3];
	TR_GetPlaneNormal(null, nrm);

	// Ground below is not walkable, not stairs
	if (nrm[2] < MIN_STANDABLE_ZNRM)
	{
		DebugMsg(client, "Stairs skip: ground below not walkable (z-normal %.3f)", nrm[2]);
		return false;
	}

	float start[3];
	TR_GetEndPosition(start);

	// Find triggers that we would trigger if we did touch the ground here.
	// If there is one, we can't be sure the stairs fix is safe to do.
	// The most likely scenario here is this isn't stairs, but just a short ledge with a fail teleport in front.
	int trigger = FindTouchableTrigger(client, start, start, mins, maxs);
	if (trigger != -1)
	{
		DebugMsg(client, "Stairs skip: trigger %i on the ground below", trigger);
		return false;
	}

	// Now follow CGameMovement::StepMove behavior.

	// Trace up
	end = start;
	end[2] += stepsize;
	TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit()) TR_GetEndPosition(end);

	// Trace over (only 1 unit, just to find a stair step)
	start = end;
	AddVectors(start, velocity_dir, end);

	TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		// The plane we collided with is too tall to be a stair step (i.e. it's a wall, not stairs).
		// Or possibly: the ceiling is too low to get on top of it.
		DebugMsg(client, "Stairs skip: face taller than step size (%.1f)", stepsize);
		return false;
	}

	// Trace downward
	start = end;
	end[2] -= stepsize;

	TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (!TR_DidHit())
	{
		DebugMsg(client, "Stairs skip: no ground on top of step");
		return false; // Shouldn't happen
	}

	TR_GetPlaneNormal(null, nrm);

	// Ground atop "stair" is not walkable, not stairs
	if (nrm[2] < MIN_STANDABLE_ZNRM)
	{
		DebugMsg(client, "Stairs skip: top of step not walkable (z-normal %.3f)", nrm[2]);
		return false;
	}

	// It looks like we actually collided with a stair step.
	// Put the player just barely on top of the stair step we found and restore their speed
	TR_GetEndPosition(end);

	DebugMsg(client, "DO FIX: Stair Sliding");

	if (SubtickOn(SUBTICK_STAIRS)) StairsLeftover(client, end, velocity_dir, mins, maxs);

	TeleportEntity(client, end, NULL_VECTOR, NULL_VECTOR);
	SetVelocity(client, g_vPreCollisionVelocity[client]);
	g_iStats[client][STAT_STAIRS]++;

	return true;
}

bool DoInclineCollisionFixes(int client, const float nrm[3])
{
	if (!g_cvDownhill.BoolValue && g_cvUphill.IntValue != UPHILL_LOSS) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	// There's no point in checking for fix if we were moving up, unless we want to do an uphill collision
	if (g_vPreCollisionVelocity[client][2] > 0.0 && g_cvUphill.IntValue != UPHILL_LOSS) return false;

	// If a collision was predicted this tick (and wasn't prevented by another fix alrady), no fix is needed.
	// It's possible we actually have to run the edge bug fix and an incline fix in the same tick.
	// If using the old Slopefix logic, do the fix regardless of necessity just like Slopefix
	// so we can be sure to trigger a double boost if applicable.
	if (g_iLastCollisionTick[client] == g_iTick[client] && !g_cvUseOldSlopefixLogic.BoolValue) return false;

	// Make sure the ground is not level, otherwise a collision would do nothing important anyway.
	if (nrm[2] == 1.0) return false;

	// This velocity includes changes from player input this tick as well as
	// the half tick of gravity applied before collision would occur.
	float velocity[3];
	velocity = g_vPreCollisionVelocity[client];

	if (g_cvUseOldSlopefixLogic.BoolValue)
	{
		// The old slopefix did not consider basevelocity when calculating deflected velocity
		SubtractVectors(velocity, g_vLastBaseVelocity[client], velocity);
	}

	float dot = nrm[0]*velocity[0] + nrm[1]*velocity[1];

	if (dot >= 0)
	{
		// If going downhill, only adjust velocity if the downhill incline fix is on.
		if (!g_cvDownhill.BoolValue) return false;
	}

	float newVelocity[3];
	bool downhillFixIsBeneficial = ClipGainsSpeed(velocity, nrm, newVelocity);

	if (dot < 0)
	{
		// If going uphill, only adjust velocity if uphill incline fix is set to loss mode
		// OR if this is actually a case where the downhill incline fix is better.
		if (!((downhillFixIsBeneficial && g_cvDownhill.BoolValue) || g_cvUphill.IntValue == UPHILL_LOSS)) return false;
	}

	DebugMsg(client, "DO FIX: Incline Collision (%s) (z-normal: %.3f)", downhillFixIsBeneficial ? "Downhill" : "Uphill", nrm[2]);

	// Make sure Z velocity is zero since we are on the ground.
	newVelocity[2] = 0.0;

	// Since we are on the ground, we also don't need to FinishGravity().

	if (g_cvUseOldSlopefixLogic.BoolValue)
	{
		// The old slopefix immediately moves basevelocity into local velocity to keep it from getting cleared.
		// This results in double boosts as the player is likely still being influenced by the source of the basevelocity.
		if (GetEntityFlags(client) & FL_BASEVELOCITY != 0)
		{
			float baseVelocity[3];
			GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
			AddVectors(newVelocity, baseVelocity, newVelocity);
		}

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newVelocity);
	}
	else
	{
		SetVelocity(client, newVelocity);
	}

	g_iStats[client][STAT_INCLINE]++;

	return true;
}

bool DoTelehopFix(int client)
{
	if (!g_cvTelehop.BoolValue) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	if (g_iLastMapTeleportTick[client] != g_iTick[client]) return false;

	// If the player was teleported two ticks in a row, don't do this fix because the player likely just passed
	// through a speed-stopping teleport hub, and the map really did want to stop the player this way.
	if (g_bMapTeleportedSequentialTicks[client]) return false;

	// Check if we either collided this tick OR landed during this tick.
	// Note that we could have landed this tick, lost Z velocity, then gotten teleported, making us no longer on the ground.
	// This is why we need to remember if we landed mid-tick rather than just check ground state now.
	if (!(g_iLastCollisionTick[client] == g_iTick[client] || g_iLastLandTick[client] == g_iTick[client])) return false;

	// rngfix_telehop 1 restores speed whatever the order. With 2, compare when the predicted move entered the
	// teleport trigger with when it first made contact, and only restore if the trigger came first.
	if (g_cvTelehop.IntValue == TELEHOP_ORDERED && g_iLastTriggerjumpTick[client] != g_iTick[client])
	{
		bool collided = g_iLastCollisionTick[client] == g_iTick[client];
		// A landing with no predicted hit is the engine snapping us down after the move, so contact is at the end.
		float contact = collided ? g_flPredContactFraction[client] : 1.0;
		float entry = g_flTeleportEntryFraction[client];

		if (entry == TELE_NOT_CROSSED && !collided)
		{
			// The prediction doesn't match the real move; give the benefit of the doubt.
			DebugMsg(client, "Telehop order: trigger not on path, contact %.3f -> unknown", contact);
			g_iStats[client][STAT_TELEHOP_UNKNOWN]++;
		}
		else if (entry == TELE_NOT_CROSSED || entry > contact + 0.001)
		{
			// Either the trigger was only reached after the collision deflected us, or it lies further along the path.
			if (entry == TELE_NOT_CROSSED) DebugMsg(client, "Telehop order: trigger not on path, contact %.3f -> skip", contact);
			else DebugMsg(client, "Telehop order: trigger %.3f, contact %.3f -> skip", entry, contact);
			g_iStats[client][STAT_TELEHOP_SKIPPED]++;
			return false;
		}
		else
		{
			DebugMsg(client, "Telehop order: trigger %.3f, contact %.3f -> restore", entry, contact);
		}
	}

	// Restore the velocity we would have had if we didn't collide or land.
	float newVelocity[3];
	newVelocity = g_vPreCollisionVelocity[client];

	// Don't forget to add the second half-tick of gravity ourselves.
	FinishGravity(client, newVelocity);

	float origin[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

	float mins[3], maxs[3];
	GetHull(client, mins, maxs);

	TR_TraceHullFilter(origin, origin, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	// If we appear to be "stuck" after teleporting (likely because the teleport destination
	// was exactly on the ground), set velocity directly to avoid side-effects of
	// TeleportEntity that can cause the player to really get stuck in the ground.
	// This might only be an issue in CSS, but do it on CSGO too just to be safe.
	bool dontUseTeleportEntity = TR_DidHit();

	DebugMsg(client, "DO FIX: Telehop%s", dontUseTeleportEntity ? " (no TeleportEntity)" : "");

	SetVelocity(client, newVelocity, dontUseTeleportEntity);
	g_iStats[client][STAT_TELEHOP]++;

	return true;
}

// PostThink works a little better than a ProcessMovement post hook because we need to wait for ProcessImpacts (trigger activation)
public void Hook_PlayerPostThink(int client)
{
	if (SkipClient(client)) return;
	if (!IsWalking(client)) return;

	int groundEnt = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");

	// Subtick credit: note whether the engine jumped us on the tick after the fixed landing.
	if (g_flSubtickCredit[client] > 0.0 && g_iSubtickKind[client] == SUBTICK_JUMP && g_iSubtickCreditTick[client] == g_iTick[client]-1
		&& g_iLastGroundEnt[client] != -1 && groundEnt == -1)
	{
		float velocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);
		if (velocity[2] > 0.0) g_iSubtickJumpTick[client] = g_iTick[client];
	}

	bool landed = groundEnt != -1 && g_iLastGroundEnt[client] == -1;

	float origin[3], landingMins[3], landingMaxs[3], nrm[3], landingPoint[3];

	// Get info about the ground we landed on (if we need to do landing fixes).
	if (landed && (g_cvTriggerjump.BoolValue || g_cvDownhill.BoolValue || g_cvUphill.IntValue == UPHILL_LOSS))
	{
		GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

		GetHull(client, landingMins, landingMaxs);

		float originBelow[3];
		originBelow[0] = origin[0];
		originBelow[1] = origin[1];
		originBelow[2] = origin[2] - LAND_HEIGHT;

		TR_TraceHullFilter(origin, originBelow, landingMins, landingMaxs, MASK_PLAYERSOLID, PlayerFilter);

		if (!TR_DidHit())
		{
			// This should never happen, since we know we are on the ground.
			landed = false;
		}
		else
		{
			TR_GetPlaneNormal(null, nrm);

			if (nrm[2] < MIN_STANDABLE_ZNRM)
			{
				// This is rare, and how the incline fix should behave isn't entirely clear because maybe we should
				// collide with multiple faces at once in this case, but let's just get the ground we officially
				// landed on and use that for our ground normal.

				// landingMins and landingMaxs will contain the final values used to find the ground after returning.
				if (TracePlayerBBoxForGround(origin, originBelow, landingMins, landingMaxs))
				{
					TR_GetPlaneNormal(null, nrm);
				}
				else
				{
					// This should also never happen.
					landed = false;
				}

				DebugMsg(client, "Used bounding box quadrant to find ground (z-normal: %.3f)", nrm[2]);
			}

			TR_GetEndPosition(landingPoint);
		}
	}

	if (landed && TR_GetFraction() > 0.0)
	{
		DoTriggerjumpFix(client, landingPoint, landingMins, landingMaxs);

		// Check if a trigger we just touched put us in the air (probably due to a teleport).
		if (GetEntityFlags(client) & FL_ONGROUND == 0) landed = false;
	}

	// The stair sliding fix changes the outcome of this tick more significantly, so it doesn't really make sense to do incline fixes too.
	if (DoStairsFix(client)) return;

	if (landed)
	{
		DoInclineCollisionFixes(client, nrm);
	}

	DoTelehopFix(client);

	GrantTeleportCredit(client);
}

public bool AddTrigger(int entity, ArrayList triggers)
{
	TR_ClipCurrentRayToEntity(MASK_ALL, entity);
	if (TR_DidHit()) triggers.Push(entity);

	return true;
}

// Edge fix: is there ground close enough to land on below the player at the end of this tick?
// Works on copies, because TracePlayerBBoxForGround leaves mins/maxs set to a quadrant.
bool CanLandBelow(const float tickEnd[3], const float mins[3], const float maxs[3])
{
	float below[3], qmins[3], qmaxs[3];
	below = tickEnd;
	below[2] -= LAND_HEIGHT;

	TR_TraceHullFilter(tickEnd, below, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);
	if (!TR_DidHit()) return false;

	// There's something there, can we land on it? Yes if it's not too steep.
	float nrm[3];
	TR_GetPlaneNormal(null, nrm);
	if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;

	// Or if the quadrant check finds ground that isn't too steep.
	qmins = mins;
	qmaxs = maxs;
	return TracePlayerBBoxForGround(tickEnd, below, qmins, qmaxs);
}

bool TracePlayerBBoxForGround(const float origin[3], const float originBelow[3], float mins[3], float maxs[3])
{
	// See CGameMovement::TracePlayerBBoxForGround()

	float origMins[3], origMaxs[3];
	origMins = mins;
	origMaxs = maxs;

	// Quadrants in the engine's order: -x -y, +x +y, -x +y, +x -y.
	// A negative side keeps mins and pulls maxs in to 0; a positive side the other way round.
	static const bool negX[4] = { true, false, true, false };
	static const bool negY[4] = { true, false, false, true };

	float nrm[3];

	for (int q = 0; q < 4; q++)
	{
		mins = origMins;
		maxs = origMaxs;

		if (negX[q]) maxs[0] = origMaxs[0] > 0.0 ? 0.0 : origMaxs[0];
		else         mins[0] = origMins[0] < 0.0 ? 0.0 : origMins[0];

		if (negY[q]) maxs[1] = origMaxs[1] > 0.0 ? 0.0 : origMaxs[1];
		else         mins[1] = origMins[1] < 0.0 ? 0.0 : origMins[1];

		TR_TraceHullFilter(origin, originBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

		if (TR_DidHit())
		{
			TR_GetPlaneNormal(null, nrm);
			if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;
		}
	}

	return false;
}
