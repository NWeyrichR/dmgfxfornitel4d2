#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <gamma_colors>

#pragma newdecls required

public Plugin myinfo = {
    name = "L4D2 Fortnite Damage (Dmgfx Fix - Part 1)",
    author = "AI Assistant",
    description = "Soma shotgun, Diretorio dmgfx, Limite 5 e Spawn",
    version = "55.3"
}


int ge_iOwner[2048];




bool g_bState[MAXPLAYERS+1]; 
Handle g_hCookie;
bool g_bSlotForceFade[MAXPLAYERS + 1][5]; 
int g_iSlotGen[MAXPLAYERS + 1][5];

int g_iNextSlot[MAXPLAYERS+1];
int g_iShotgunSum[MAXPLAYERS+1];
bool g_bShotgunActive[MAXPLAYERS+1];
bool g_bShotgunCrit[MAXPLAYERS+1];
float g_vShotgunPos[MAXPLAYERS+1][3]; // Salva onde o primeiro balim pegou

ConVar g_cvScale, g_cvSpacing, g_cvRate, g_cvBurst, g_cvMaxScale;
float g_fTokens[MAXPLAYERS+1];
float g_fLastTokenUpdate[MAXPLAYERS+1];
int g_iDeathBlockRef[2048];
float g_fDeathBlockUntil[2048];
int g_iTankHP[MAXPLAYERS+1];
int g_iTankRef[MAXPLAYERS+1];
char g_sSpritePath[] = "materials/dmgfx/numbers.vmt"; 
bool g_bTakeDamageHooked[MAXPLAYERS + 1];

public void OnPluginStart() {
    g_cvScale = CreateConVar("sm_damage_scale", "0.08", "Escala base");
    g_cvSpacing = CreateConVar("sm_damage_spacing", "7.0", "Distancia");
    g_cvRate = CreateConVar("sm_damage_rate", "40.0", "Limite de numeros por segundo (por jogador). 0 = desativado");
    g_cvBurst = CreateConVar("sm_damage_burst", "20.0", "Burst maximo de numeros (por jogador).");
    g_cvMaxScale = CreateConVar("sm_damage_max_scale", "0.12", "Escala maxima do numero (cap) para distancias longas. 0 = sem limite");
    RegConsoleCmd("sm_hits", Command_ToggleHits);
    g_hCookie = RegClientCookie("fortnite_hits_state", "Estado", CookieAccess_Protected);
    HookEvent("player_hurt", Event_Damage);
    HookEvent("infected_hurt", Event_Damage);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_spawn", Event_PlayerSpawn);

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;
        EnsureTakeDamageHook(i);
    }
}

public void OnMapStart() { 
    PrecacheModel(g_sSpritePath, true); 
    AddFileToDownloadsTable("materials/dmgfx/numbers.vmt"); 
    AddFileToDownloadsTable("materials/dmgfx/numbers.vtf"); 
}

public void OnClientCookiesCached(int client) {
    char buff[4]; GetClientCookie(client, g_hCookie, buff, sizeof(buff));
    g_bState[client] = (buff[0] == '\0' || StringToInt(buff) == 1);
}


public Action Command_ToggleHits(int client, int args) {
    if (client == 0) return Plugin_Handled;
    g_bState[client] = !g_bState[client];
    char b[4]; IntToString(g_bState[client], b, sizeof(b)); SetClientCookie(client, g_hCookie, b);
    GCPrintToChat(client, "{default}[{green}HITS{default}] %s", g_bState[client] ? "{green}ATIVADO" : "{red}DESATIVADO");
    return Plugin_Handled;
}

// --- VISIBILIDADE (SÓ O AGRESSOR VÊ) ---
public Action OnTransmit(int entity, int client) {
    // Se o cliente tentando ver não for EXATAMENTE o dono do sprite, bloqueia.
    if (ge_iOwner[entity] != client) {
        return Plugin_Stop; 
    }
    return Plugin_Continue;
}

bool IsVictimDyingOrDead(int victim)
{
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return true;

    int lifeState = 0;
    if (HasEntProp(victim, Prop_Send, "m_lifeState"))
        lifeState = GetEntProp(victim, Prop_Send, "m_lifeState");
    else if (HasEntProp(victim, Prop_Data, "m_lifeState"))
        lifeState = GetEntProp(victim, Prop_Data, "m_lifeState");
    else if (victim <= MaxClients)
        return !IsPlayerAlive(victim);

    if (lifeState != 0) return true;

    int health = 0;
    if (HasEntProp(victim, Prop_Send, "m_iHealth"))
        health = GetEntProp(victim, Prop_Send, "m_iHealth");
    else if (HasEntProp(victim, Prop_Data, "m_iHealth"))
        health = GetEntProp(victim, Prop_Data, "m_iHealth");
    else
        return false;

    return (health <= 0);
}

bool IsDeathAnimBlocked(int victim)
{
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return false;
    if (g_iDeathBlockRef[victim] == 0) return false;
    if (EntIndexToEntRef(victim) != g_iDeathBlockRef[victim]) return false;
    return (GetGameTime() < g_fDeathBlockUntil[victim]);
}

void BlockDeathAnim(int victim, float duration)
{
    if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim)) return;
    g_iDeathBlockRef[victim] = EntIndexToEntRef(victim);
    g_fDeathBlockUntil[victim] = GetGameTime() + duration;
}

bool IsClientTank(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return false;
    if (GetClientTeam(client) != 3) return false;
    if (!HasEntProp(client, Prop_Send, "m_zombieClass")) return false;
    return (GetEntProp(client, Prop_Send, "m_zombieClass") == 8);
}

bool ShouldBlockTankDeathFromHurt(Event event, int victim)
{
    if (!IsClientTank(victim)) return false;

    int damage = event.GetInt("dmg_health");
    if (damage <= 0) damage = event.GetInt("amount");
    if (damage <= 0) return false;

    int eventHP = event.GetInt("health");
    if (eventHP < 0) eventHP = 0;

    int ref = EntIndexToEntRef(victim);
    if (g_iTankRef[victim] != ref) {
        g_iTankRef[victim] = ref;
        g_iTankHP[victim] = eventHP + damage;
    }

    g_iTankHP[victim] -= damage;
    if (eventHP > 0 && eventHP < g_iTankHP[victim]) g_iTankHP[victim] = eventHP;

    if (g_iTankHP[victim] <= 0) {
        BlockDeathAnim(victim, 15.0);
        return true;
    }
    return false;
}

bool ConsumeTokens(int attacker, int cost)
{
    if (attacker <= 0 || attacker > MaxClients) return false;

    float rate = g_cvRate.FloatValue;
    float burst = g_cvBurst.FloatValue;
    if (rate <= 0.0 || burst <= 0.0) return true; // desativado

    float now = GetGameTime();
    float dt = now - g_fLastTokenUpdate[attacker];
    if (dt < 0.0) dt = 0.0;

    g_fTokens[attacker] += dt * rate;
    if (g_fTokens[attacker] > burst) g_fTokens[attacker] = burst;
    g_fLastTokenUpdate[attacker] = now;

    float fCost = float(cost);
    if (g_fTokens[attacker] < fCost) return false;

    g_fTokens[attacker] -= fCost;
    return true;
}

public Action Timer_Collect(Handle timer, DataPack pack) {
    pack.Reset();
    int attacker = GetClientOfUserId(pack.ReadCell());
    int victim = pack.ReadCell();
    // REMOVIDO: delete pack; (O CreateDataTimer já faz isso)

    if (attacker > 0 && IsValidEntity(victim) && !IsDeathAnimBlocked(victim) && !IsVictimDyingOrDead(victim)) {
        SpawnEverything(attacker, g_iShotgunSum[attacker], victim, g_bShotgunCrit[attacker], true);
        
        g_iShotgunSum[attacker] = 0;
        g_bShotgunActive[attacker] = false;
    }
    return Plugin_Stop;
}

public Action Timer_CollectShotgun(Handle timer, DataPack pack) {
    pack.Reset();
    int attacker = GetClientOfUserId(pack.ReadCell());
    int victim = pack.ReadCell();
    // REMOVIDO: delete pack; (O CreateDataTimer já faz isso)

    if (attacker > 0 && IsClientInGame(attacker)) {
        if (!IsDeathAnimBlocked(victim) && !IsVictimDyingOrDead(victim)) {
            SpawnEverything(attacker, g_iShotgunSum[attacker], victim, g_bShotgunCrit[attacker], true);
        }
        
        g_iShotgunSum[attacker] = 0;
        g_bShotgunActive[attacker] = false;
        g_bShotgunCrit[attacker] = false;
    }
    return Plugin_Stop;
}

// --- MOVIMENTO NATURAL (REQUESTFRAME) ---
public void Frame_MasterLogic(DataPack pack) {
    pack.Reset();
    int attacker = GetClientOfUserId(pack.ReadCell());
    int len = pack.ReadCell();
    int ticks = pack.ReadCell();
    int alpha = pack.ReadCell();
    float p[3]; p[0] = pack.ReadFloat(); p[1] = pack.ReadFloat(); p[2] = pack.ReadFloat();
    float hVel = pack.ReadFloat(); float vVel = pack.ReadFloat();
    int slot = pack.ReadCell();
    int gen = pack.ReadCell();

    // Ler os sprites para um array local antes de resetar o pack para escrita
    int sprites[16];
    for (int i = 0; i < len; i++) sprites[i] = pack.ReadCell();

    bool killNow = (attacker <= 0 || !IsClientInGame(attacker) || alpha <= 10);
    if (!killNow && slot >= 0 && slot < 5 && g_iSlotGen[attacker][slot] != gen) killNow = true;

    if (killNow) {
        for (int i = 0; i < len; i++) {
            int ent = EntRefToEntIndex(sprites[i]);
            if (ent > MaxClients && IsValidEntity(ent)) AcceptEntityInput(ent, "Kill");
        }
        delete pack; return;
    }

    ticks++; 
    alpha -= (g_bSlotForceFade[attacker][slot] ? 40 : 8); 
    vVel -= 0.6; p[2] += vVel;

    float vEyePos[3], vEyeAng[3], vRight[3];
    GetClientEyePosition(attacker, vEyePos); GetClientEyeAngles(attacker, vEyeAng);
    GetAngleVectors(vEyeAng, NULL_VECTOR, vRight, NULL_VECTOR);
    p[0] += vRight[0] * hVel; p[1] += vRight[1] * hVel;

    // AQUI ESTAVA O ERRO: Reescrever o pack corretamente para o próximo frame
    pack.Reset();
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteCell(len);
    pack.WriteCell(ticks);
    pack.WriteCell(alpha);
    pack.WriteFloat(p[0]); pack.WriteFloat(p[1]); pack.WriteFloat(p[2]);
    pack.WriteFloat(hVel); pack.WriteFloat(vVel);
    pack.WriteCell(slot);
    pack.WriteCell(gen);
    for (int i = 0; i < len; i++) pack.WriteCell(sprites[i]);

    float split = (ticks > 25) ? (float(ticks - 25) * 1.5) : 0.0;

    for (int i = 0; i < len; i++) {
        int sprite = EntRefToEntIndex(sprites[i]);
        if (sprite <= MaxClients || !IsValidEntity(sprite)) continue;
        
        float offset = (float(i) - (float(len - 1) / 2.0)) * (g_cvSpacing.FloatValue + split);
        float dPos[3];
        dPos[0] = p[0] + (vRight[0] * offset); dPos[1] = p[1] + (vRight[1] * offset); dPos[2] = p[2];

        float lookVec[3];
        MakeVectorFromPoints(dPos, vEyePos, lookVec);

        // Angulo mais estavel (evita flip quando o player esta muito acima/abaixo)
        float fullAng[3];
        GetVectorAngles(lookVec, fullAng);
        fullAng[0] *= -1.0;

        float yawVec[3];
        yawVec[0] = lookVec[0];
        yawVec[1] = lookVec[1];
        yawVec[2] = 0.0;

        float yawAng[3];
        float horiz = SquareRoot(yawVec[0] * yawVec[0] + yawVec[1] * yawVec[1]);
        float yaw = 0.0;
        if (horiz < 0.001) yaw = vEyeAng[1] + 180.0;
        else {
            GetVectorAngles(yawVec, yawAng);
            yaw = yawAng[1] + 180.0;
        }

        float pitch = fullAng[0];
        if (pitch > 80.0) pitch = 80.0;
        else if (pitch < -80.0) pitch = -80.0;

        float lookAng[3];
        lookAng[0] = pitch;
        lookAng[1] = yaw;
        lookAng[2] = 0.0;

        TeleportEntity(sprite, dPos, lookAng, NULL_VECTOR);
        
        // Escala Baseada na Distancia
        float dist = GetVectorDistance(vEyePos, dPos);
        float dynamicScale = (dist / 450.0) * g_cvScale.FloatValue;
        float maxScale = g_cvMaxScale.FloatValue;
        if (maxScale > 0.0 && dynamicScale > maxScale) dynamicScale = maxScale;
        if (ticks <= 6) dynamicScale *= (0.5 + (float(ticks) * 0.15));
        
        SetVariantFloat(dynamicScale); AcceptEntityInput(sprite, "SetScale");

        int r, g, b, a_old; GetEntityRenderColor(sprite, r, g, b, a_old);
        SetEntityRenderColor(sprite, r, g, b, (alpha < 0 ? 0 : alpha));
    }
    RequestFrame(Frame_MasterLogic, pack);
}

void SpawnEverything(int attacker, int damage, int victim, bool crit, bool isShotgun) {
    char sDmg[16]; 
    IntToString(damage, sDmg, sizeof(sDmg));
    int len = strlen(sDmg); 
    float vPos[3]; // USANDO: Variável de posição
    
    // USANDO: isShotgun e victim para definir onde o número nasce
    // Limite para evitar crash em spam (molotov, hordas, etc.)
    if (len <= 0 || len > sizeof(sDmg) - 1) return;
    if (!ConsumeTokens(attacker, len)) return;

    // Evita spam/bug durante animacao de morte (ex: Tank queimando e "chovendo 1")
    if (victim > 0 && victim <= MaxClients) {
        if (!IsClientInGame(victim)) return;
        if (IsDeathAnimBlocked(victim) || IsVictimDyingOrDead(victim)) return;
    }

    if (isShotgun) {
        vPos[0] = g_vShotgunPos[attacker][0];
        vPos[1] = g_vShotgunPos[attacker][1];
        vPos[2] = g_vShotgunPos[attacker][2];
    } else {
        if (victim > 0 && victim <= MaxClients) GetClientAbsOrigin(victim, vPos);
        else GetEntPropVector(victim, Prop_Send, "m_vecOrigin", vPos);
    }
    vPos[2] += 55.0;

    // USANDO: attacker, victim e crit para definir a cor
    int r = 255, g = 255, b = 255;
    if (victim > 0 && victim <= MaxClients && GetClientTeam(attacker) == GetClientTeam(victim)) {
        r = 255; g = 0; b = 0; // Vermelho se for Team Kill
    } else if (crit) {
        r = 255; g = 255; b = 0; // Amarelo se for Crítico
    }

    // Preparando o envio para o movimento suave
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteCell(len);
    pack.WriteCell(0);    // Ticks
    pack.WriteCell(255);  // Alpha
    pack.WriteFloat(vPos[0]); pack.WriteFloat(vPos[1]); pack.WriteFloat(vPos[2]);
    pack.WriteFloat(GetRandomFloat(-3.5, 3.5)); // hVel
    pack.WriteFloat(10.0); // vVel
    
    int slot = g_iNextSlot[attacker];
    g_iNextSlot[attacker] = (slot + 1) % 5;
    int gen = ++g_iSlotGen[attacker][slot];
    pack.WriteCell(slot);
    pack.WriteCell(gen);
    g_bSlotForceFade[attacker][slot] = false;

    for (int i = 0; i < len; i++) {
        int sprite = CreateEntityByName("env_sprite_oriented");
        if (sprite == -1) continue;
        
        ge_iOwner[sprite] = attacker; // USANDO: attacker aqui para visibilidade
        DispatchKeyValue(sprite, "model", g_sSpritePath);
        DispatchKeyValue(sprite, "rendermode", "1"); 
        DispatchSpawn(sprite);
        
        SetEntPropFloat(sprite, Prop_Data, "m_flFrame", float(sDmg[i] - '0'));
        SetEntityRenderColor(sprite, r, g, b, 255); // USANDO: r, g, b aqui

        SDKHook(sprite, SDKHook_SetTransmit, OnTransmit);
        pack.WriteCell(EntIndexToEntRef(sprite));
    }
    
    RequestFrame(Frame_MasterLogic, pack);
}

public void Event_Damage(Event event, const char[] name, bool dontBroadcast) {
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = (StrEqual(name, "player_hurt")) ? GetClientOfUserId(event.GetInt("userid")) : event.GetInt("entityid");

    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker) || IsFakeClient(attacker) || attacker == victim || !g_bState[attacker]) 
        return;

    // Tank/SI: detecta o frame exato que a vida chega a 0 (player_death pode vir so depois da animacao)
    if (StrEqual(name, "player_hurt")) {
        int remainingHP = event.GetInt("health");
        if (victim > 0 && victim <= MaxClients && remainingHP <= 0) {
            BlockDeathAnim(victim, 15.0);
            return;
        }

        // Tank: se o "health" do evento vier bugado, usa tracking por dano para cortar no 0.
        if (victim > 0 && victim <= MaxClients && ShouldBlockTankDeathFromHurt(event, victim)) {
            return;
        }
    }

    if (IsDeathAnimBlocked(victim)) return;
    if (victim > 0 && IsValidEntity(victim) && IsVictimDyingOrDead(victim))
        return;

    int damage = event.GetInt("amount"); 
    if (damage <= 0) damage = event.GetInt("dmg_health");

    // --- FIX PARA WITCH E COMMONS ---
    char weapon[32]; 
    event.GetString("weapon", weapon, sizeof(weapon));

    int dmgType = event.GetInt("type");
    bool bulletLike = (dmgType == 0) || ((dmgType & (DMG_BULLET | DMG_BUCKSHOT)) != 0);

    // Se o nome da arma vier vazio (comum em Witch/Infected), pegamos a arma ativa do jogador
    if (weapon[0] == '\0' && bulletLike) {
        int iWep = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
        if (iWep > 0 && IsValidEntity(iWep)) {
            GetEntityClassname(iWep, weapon, sizeof(weapon));
        }
    }

    // Verifica se é shotgun (agora detecta chrome, spas, pump e auto)
    bool isShotgun = (StrContains(weapon, "shotgun") != -1 || StrContains(weapon, "spas") != -1);
    if (dmgType != 0) isShotgun = (isShotgun && ((dmgType & (DMG_BULLET | DMG_BUCKSHOT)) != 0));

    if (isShotgun) {
        if (!g_bShotgunActive[attacker]) {
            g_bShotgunActive[attacker] = true;
            g_iShotgunSum[attacker] = damage;
            g_bShotgunCrit[attacker] = (event.GetInt("hitgroup") == 1);
            
            if (victim > 0 && IsValidEntity(victim)) {
                if (victim <= MaxClients) GetClientAbsOrigin(victim, g_vShotgunPos[attacker]);
                else GetEntPropVector(victim, Prop_Send, "m_vecOrigin", g_vShotgunPos[attacker]);
            }

            DataPack pack = new DataPack();
            // Aumentamos levemente para 0.15 para garantir que pegue todos os balins de longe
            CreateDataTimer(0.15, Timer_CollectShotgun, pack); 
            pack.WriteCell(GetClientUserId(attacker));
            pack.WriteCell(victim);
        } else {
            g_iShotgunSum[attacker] += damage;
            if (event.GetInt("hitgroup") == 1) g_bShotgunCrit[attacker] = true;
        }
    } else {
        SpawnEverything(attacker, damage, victim, (event.GetInt("hitgroup") == 1), false);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return;

    // Bloqueia o spam de dano durante animacao de morte (ex: Tank queimando e "chovendo 1")
    BlockDeathAnim(victim, 15.0);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client >= 2048) return;
    g_iDeathBlockRef[client] = 0;
    g_fDeathBlockUntil[client] = 0.0;
    if (client <= MaxClients) {
        g_iTankRef[client] = 0;
        g_iTankHP[client] = 0;
    }
}

public bool Filter_World(int entity, int mask) { return (entity == 0); }

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients) return;
    g_bTakeDamageHooked[client] = false;
    EnsureTakeDamageHook(client);
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients) return;
    g_bTakeDamageHooked[client] = false;
}

void EnsureTakeDamageHook(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client)) return;
    if (g_bTakeDamageHooked[client]) return;

    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage_BlockTankLethal);
    g_bTakeDamageHooked[client] = true;
}

public Action OnTakeDamage_BlockTankLethal(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (victim <= 0 || victim > MaxClients) return Plugin_Continue;
    if (!IsClientInGame(victim)) return Plugin_Continue;
    if (!IsClientTank(victim)) return Plugin_Continue;
    if (IsDeathAnimBlocked(victim)) return Plugin_Continue;

    if (attacker <= 0 || attacker > MaxClients) return Plugin_Continue;
    if (!IsClientInGame(attacker) || IsFakeClient(attacker)) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;

    int hp = GetClientHealth(victim);
    if (hp <= 0) return Plugin_Continue;

    int dmg = RoundToCeil(damage);
    if (dmg <= 0) return Plugin_Continue;

    if (dmg >= hp) {
        BlockDeathAnim(victim, 15.0);
    }

    return Plugin_Continue;
}
