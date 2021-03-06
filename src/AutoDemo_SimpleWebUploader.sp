#include <sourcemod>
#include <AutoDemo>
#include <convars>
#include <ripext>

// Default chunk size is 5 MiB
#define DEFAULT_CHUNK_SIZE  5000000

// File permissions
#define FPERM_U_ALL         FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC
#define FPERM_G_ALL         FPERM_G_READ | FPERM_G_WRITE | FPERM_G_EXEC
#define FPERM_O_ALL         FPERM_O_READ | FPERM_O_WRITE | FPERM_O_EXEC
#define FPERM_EVERYTHING    FPERM_U_ALL | FPERM_G_ALL | FPERM_O_ALL

bool    g_bAutoCleanup;
char    g_szRemoteUrl[256];
char    g_szSecretKey[128];
char    g_szUserAgent[128];
int     g_iChunkSize;
int     g_iMaxSpeed;

ConVar  g_hAutoCleanup;
ConVar  g_hRemoteUrl;
ConVar  g_hSecretKey;
ConVar  g_hUserAgent;
ConVar  g_hMaxSpeed;

bool    g_bIsPlannedRequestChunkSize;
bool    g_bReady;

public Plugin myinfo = {
    description = "Simple uploader for simple web",
    version = "0.2.0.3",
    author = "Bubuni",
    name = "[AutoDemo] Simple Web Uploader",
    url = "https://github.com/Bubuni-Team"
};

public void OnPluginStart()
{
    g_hAutoCleanup = CreateConVar("sm_autodemo_sdu_auto_cleanup", "0", "Delete uploaded/cancelled demo-records?", _, true, 0.0, true, 1.0); // since 0.2.0.0
    g_hRemoteUrl = CreateConVar("sm_autodemo_sdu_url", "", "URL to web installation");
    g_hSecretKey = CreateConVar("sm_autodemo_sdu_key", "", "Secret server key");
    g_hUserAgent = CreateConVar("sm_autodemo_sdu_user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0");
    g_hMaxSpeed = CreateConVar("sm_autodemo_sdu_max_speed", "0", "Max speed for uploading (in bytes per second). 0 means \"no limit\".", _, true, 0.0);
    AutoExecConfig(true, "autodemo_simpleuploader");

    HookConVarChange(g_hAutoCleanup, OnConVarChanged);
    HookConVarChange(g_hRemoteUrl, OnConVarChanged);
    HookConVarChange(g_hSecretKey, OnConVarChanged);
    HookConVarChange(g_hUserAgent, OnConVarChanged);
    HookConVarChange(g_hMaxSpeed, OnConVarChanged);

    RegServerCmd("sm_autodemo_sdu_reconfigure", CmdReconfigure);
    RegServerCmd("sm_autodemo_sdu_upload", CmdUpload);
}

public void OnConVarChanged(ConVar hCvar, const char[] szOV, const char[] szNV)
{
    OnConfigsExecuted();
}

public Action CmdReconfigure(int iArgC)
{
    ReplyToCommand(0, "[SM] Enqueued requesting chunk size");
    OnRequestChunkSize(0);
    return Plugin_Handled;
}

public Action CmdUpload(int iArgC)
{
    if (iArgC == 0)
    {
        ReplyToCommand(0, "[SM] Usage: sm_autodemo_sdu_upload <demo_id>");
        return Plugin_Handled;
    }

    char szDemoId[40];
    if (iArgC == 1) GetCmdArg(1, szDemoId, sizeof(szDemoId));
    else GetCmdArgString(szDemoId, sizeof(szDemoId));

    DemoRec_OnRecordStop(szDemoId);
    ReplyToCommand(0, "[SM] Triggered internal OnRecordStop handler for demo identifier %s", szDemoId);
    return Plugin_Handled;
}

public void OnConfigsExecuted()
{
    g_bReady = false;
    g_bAutoCleanup = GetConVarBool(g_hAutoCleanup);
    GetConVarString(g_hRemoteUrl, g_szRemoteUrl, sizeof(g_szRemoteUrl));
    GetConVarString(g_hSecretKey, g_szSecretKey, sizeof(g_szSecretKey));
    GetConVarString(g_hUserAgent, g_szUserAgent, sizeof(g_szUserAgent));
    g_iMaxSpeed = g_hMaxSpeed.IntValue;

    if (!g_bIsPlannedRequestChunkSize)
    {
        RequestFrame(OnRequestChunkSize);
    }
}

public void OnRequestChunkSize(any data)
{
    g_bIsPlannedRequestChunkSize = false;
    MakeRequest("config").Get(OnConfigReceived);
}

public void DemoRec_OnRecordStop(const char[] szDemoId)
{
    if (!g_bReady)
    {
        return;
    }

    char szBasePath[192];
    char szFullPath[PLATFORM_MAX_PATH];

    DemoRec_GetDataDirectory(szBasePath, sizeof(szBasePath));
    FormatEx(szFullPath, sizeof(szFullPath), "%s/%s.dem", szBasePath, szDemoId);

    DataPack hTask = new DataPack();
    hTask.WriteString(szDemoId);
    hTask.WriteString(szFullPath);
    hTask.WriteCell(0);
    hTask.WriteCell(UTIL_CalculateChunkCount(szFullPath, g_iChunkSize));

    RunTask(hTask, 1.0);
}

public Action OnRunDelayedTask(Handle hTimer, DataPack hTask)
{
    RunTask(hTask);
}

void RunTask(DataPack hTask, float flDelay = -1.0)
{
    if (flDelay >= 0.0)
    {
        CreateTimer(flDelay, OnRunDelayedTask, hTask);
        return;
    }

    char szDemoId[40];
    char szDemoSource[PLATFORM_MAX_PATH];

    hTask.Reset();
    hTask.ReadString(szDemoId, sizeof(szDemoId));
    hTask.ReadString(szDemoSource, sizeof(szDemoSource));
    int iChunkId = hTask.ReadCell();
    int iChunkCount = hTask.ReadCell();

    if (iChunkId == iChunkCount)
    {
        FinishTask(hTask);
        return;
    }

    char szChunkPath[PLATFORM_MAX_PATH];
    if (iChunkCount > 1)
    {
        BuildPath(Path_SM, szChunkPath, sizeof(szChunkPath), "data/ad_chunk.bin");
        if (!UTIL_MakeChunk(szDemoSource, szChunkPath, iChunkId, g_iChunkSize))
        {
            // TODO: delete all demo chunks from web? or try again create later?
            CancelTask(hTask);
            return;
        }
    }
    else
    {
        // If chunk count - 1, then we don't need create chunk. Just pass source file.
        strcopy(szChunkPath, sizeof(szChunkPath), szDemoSource);
    }

    // Rewrite in task all data.
    hTask.Reset(true);
    hTask.WriteString(szDemoId);
    hTask.WriteString(szDemoSource);
    hTask.WriteCell(iChunkId + 1);
    hTask.WriteCell(iChunkCount);

    HTTPRequest hRequest = MakeRequest("upload", true);
    hRequest.AppendQueryParam("demo_id", szDemoId);
    hRequest.AppendQueryParam("chunk_id", UTIL_IntToString(iChunkId));
    hRequest.UploadFile(szChunkPath, OnChunkUploaded, hTask);
}

void FinishTask(DataPack hTask)
{
    char szDemoId[40];
    hTask.Reset();
    hTask.ReadString(szDemoId, sizeof(szDemoId));

    char szBasePath[192];
    char szJsonPath[PLATFORM_MAX_PATH];
    DemoRec_GetDataDirectory(szBasePath, sizeof(szBasePath));
    FormatEx(szJsonPath, sizeof(szJsonPath), "%s/%s.json", szBasePath, szDemoId);

    JSONObject hRequestBody = JSONObject.FromFile(szJsonPath);

    MakeRequest("finish").Post(hRequestBody, OnDemoCreated, hTask);
    hRequestBody.Close();
}

void CancelTask(DataPack hTask)
{
    char szDemoId[40],
        szDemoSource[PLATFORM_MAX_PATH];

    hTask.Reset();
    hTask.ReadString(szDemoId, sizeof(szDemoId));
    hTask.ReadString(szDemoSource, sizeof(szDemoSource));

    if (g_bAutoCleanup)
    {
        // 1. Delete .dem file.
        DeleteFile(szDemoSource);

        // 2. Delete .json file.
        int iExtPos = strlen(szDemoSource) - 3;
        strcopy(szDemoSource[iExtPos], sizeof(szDemoSource), "json");
        DeleteFile(szDemoSource);

        LogMessage("Deleted demo-record with identifier '%s'", szDemoId);
    }
}

/**
 * @section HTTP callbacks
 */
public void OnConfigReceived(HTTPResponse hResponse, any value, const char[] szError)
{
    if (!hResponse)
    {
        LogError("Couldn't receive configuration from HTTP API: %s", szError);
        return;
    }

    if (hResponse.Status != HTTPStatus_OK)
    {
        LogError("Received unexpected HTTP status when fetching configuration: %d (%s)", hResponse.Status, szError);
        return;
    }

    g_iChunkSize = (view_as<JSONObject>(hResponse.Data)).GetInt("chunkSize") - 1000;
    g_bReady = true;

    LogMessage("[DEBUG] Chunk size - %d bytes", g_iChunkSize);
}

public void OnChunkUploaded(HTTPStatus iStatus, any iTask, const char[] szError)
{
    DataPack hTask = view_as<DataPack>(iTask);
    if (iStatus != HTTPStatus_Created)
    {
        LogError("Couldn't upload chunk: %d (%s)", iStatus, szError);
        CancelTask(hTask);
        return;
    }

    RunTask(hTask);
}

public void OnDemoCreated(HTTPResponse hResponse, any iTask, const char[] szError)
{
    DataPack hTask = view_as<DataPack>(iTask);
    CancelTask(hTask);
    if (!hResponse)
    {
        LogError("Couldn't create demo in database: %s", szError);
        return;
    }

    if (hResponse.Status != HTTPStatus_Created)
    {
        LogError("Received unexpected HTTP status when uploading a demo information: %d (%s)", hResponse.Status, szError);
        return;
    }
}

stock char UTIL_IntToString(int iValue)
{
    char szValue[16];
    IntToString(iValue, szValue, sizeof(szValue));

    return szValue;
}

stock HTTPRequest MakeRequest(const char[] szMethod, bool bApplySpeedLimitations = false)
{
    PrintToServer("  -> MakeRequest(): base url %s, method %s", g_szRemoteUrl, szMethod);
    HTTPRequest hRequest = new HTTPRequest(g_szRemoteUrl);
    hRequest.AppendQueryParam("controller", "api");
    hRequest.AppendQueryParam("action", szMethod);
    hRequest.AppendQueryParam("key", g_szSecretKey);

    if (g_szUserAgent[0])
    {
        hRequest.SetHeader("User-Agent", g_szUserAgent);
    }

    if (bApplySpeedLimitations)
    {
        hRequest.MaxSendSpeed = g_iMaxSpeed;
        hRequest.MaxRecvSpeed = g_iMaxSpeed;
    }

    return hRequest;
}

stock bool UTIL_MakeChunk(const char[] szSource, const char[] szTarget, int iChunk = 0, int iChunkSize = DEFAULT_CHUNK_SIZE)
{
    File hSource = OpenFile(szSource, "rb");
    File hTarget = OpenFile(szTarget, "wb");
    if (!hSource || !hTarget)
    {
        LogError("Couldn't open source (%x)/target (%x) file", hSource, hTarget);
        hSource.Close();
        hTarget.Close();
        return false;
    }

    if (iChunk)
    {
        if (!hSource.Seek(iChunkSize * iChunk, SEEK_SET))
        {
            LogError("Couldn't seek required position for chunk %d", iChunk);
            hSource.Close();
            hTarget.Close();
            return false;
        }
    }

    // Kruzya: ?????? ???????????????????????? ??????????????????????, ???????????? ?????????????? ???????? ??????????,
    // ?????????????????????? ChunkSize ?? ?????????????????????? ???? ?????????????? ??????????.
    //
    // 20.06.2021

    iChunkSize = UTIL_Min(iChunkSize, FileSize(szSource) - (iChunkSize * iChunk));

    int buffer[4096];
    int iBytesWritten = 0;
    int iChunkRead = 0;
    int iBytesPerCell = 4;
    do
    {
        // Kruzya: ???????????????? ?? ??????, ?????? ???????? ???????????????????? ?? ???????????????????? ???? 1 ??????????
        // ??????????????????, ???? ???????? ?????????????? ?????????? ???????????????????? ????????. ???????? ??????????????????
        // ???????? ????????????????.
        //
        // ???????????? ???? ???????????????? ???????????? ?????????????????? ????????: ???????? ?????????? ?????????????????? ??????
        // 16384 ???????? ?? ??????????, ???? ???????????? ?? ???????????? ???????????? ???? 4 ??????????. ?? ????????
        // ?????????? 16384 ???????? - ?????????? ???? 1 ?????????? ?? ????????????. ?????? ???????????? ????????????????
        // ???????????? ???? ???????????????????? 99% ??????????, ?? ???????? ???? 1% - ????????????????????????????.
        //
        // 20.06.2021

        if ((iChunkSize - iBytesWritten) < 16384)
        {
            iBytesPerCell = 1;
        }

        iChunkRead = hSource.Read(buffer, UTIL_Min(sizeof(buffer), (iChunkSize - iBytesWritten) / iBytesPerCell), iBytesPerCell);

        hTarget.Write(buffer, iChunkRead, iBytesPerCell);
        iBytesWritten += iChunkRead * iBytesPerCell;
        if (hSource.EndOfFile())
        {
            break;
        }
    }
    while (iBytesWritten < iChunkSize);

    hSource.Close();
    hTarget.Close();
    return true;
}

stock int UTIL_CalculateChunkCount(const char[] szSource, int iChunkSize = DEFAULT_CHUNK_SIZE)
{
    int iFileSize = FileSize(szSource);
    return RoundToCeil(float(iFileSize) / float(iChunkSize));
}

stock int UTIL_Min(int a, int b)
{
    return (a < b ? a : b);
}
