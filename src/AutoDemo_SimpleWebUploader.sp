#include <sourcemod>
#include <autodemo>
#include <convars>
#include <ripext>

// Default chunk size is 5 MiB
#define DEFAULT_CHUNK_SIZE  5000000

// File permissions
#define FPERM_U_ALL         FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC
#define FPERM_G_ALL         FPERM_G_READ | FPERM_G_WRITE | FPERM_G_EXEC
#define FPERM_O_ALL         FPERM_O_READ | FPERM_O_WRITE | FPERM_O_EXEC
#define FPERM_EVERYTHING    FPERM_U_ALL | FPERM_G_ALL | FPERM_O_ALL

char    g_szChunkDirectory[PLATFORM_MAX_PATH];
char    g_szRemoteUrl[256];
char    g_szSecretKey[128];
int     g_iChunkSize;

ConVar  g_hRemoteUrl;
ConVar  g_hSecretKey;

bool    g_bIsPlannedRequestChunkSize;
bool    g_bReady;

public Plugin myinfo = {
    description = "Simple uploader for simple web",
    version = "0.0.0.1",
    author = "Bubuni",
    name = "[AutoDemo] Simple Web Uploader",
    url = "https://github.com/Bubuni-Team"
};

public void OnPluginStart()
{
    BuildPath(Path_SM, g_szChunkDirectory, sizeof(g_szChunkDirectory), "autodemo_chunks");
    if (!DirExists(g_szChunkDirectory))
    {
        CreateDirectory(g_szChunkDirectory, FPERM_EVERYTHING);
    }

    g_hRemoteUrl = CreateConVar("sm_autodemo_sdu_url", "", "URL to web installation");
    g_hSecretKey = CreateConVar("sm_autodemo_sdu_key", "", "Secret server key");
    AutoExecConfig(true, "autodemo_simpleuploader");

    HookConVarChange(g_hRemoteUrl, OnConVarChanged);
    HookConVarChange(g_hSecretKey, OnConVarChanged);
}

public void OnConVarChanged(ConVar hCvar, const char[] szOV, const char[] szNV)
{
    OnConfigsExecuted();
}

public void OnConfigsExecuted()
{
    g_bReady = false;
    GetConVarString(g_hRemoteUrl, g_szRemoteUrl, sizeof(g_szRemoteUrl));
    GetConVarString(g_hSecretKey, g_szSecretKey, sizeof(g_szSecretKey));

    if (!g_bIsPlannedRequestChunkSize)
    {
        RequestFrame(OnRequestChunkSize);
    }
}

public void OnRequestChunkSize(any data)
{
    g_bIsPlannedRequestChunkSize = false;

    // TODO: рефакторинг запроса под веб
    HTTPRequest hRequest = new HTTPRequest(g_szRemoteUrl);
    hRequest.AppendQueryParam("key", g_szSecretKey);
    hRequest.AppendQueryParam("operation", "config");
    hRequest.Get(OnConfigReceived);
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

    RunTask(hTask);
}

public void RunTask(DataPack hTask)
{
    char szDemoId[40];
    char szDemoSource[PLATFORM_MAX_PATH];

    hTask.Reset();
    hTask.ReadString(szDemoId, sizeof(szDemoId));
    hTask.ReadString(szDemoSource, sizeof(szDemoSource));
    int iChunkId = hTask.ReadCell();
    int iChunkCount = hTask.ReadCell();

    if (iChunkId == iChunkCount)
    {
        FinishTask(szDemoId);
        hTask.Close();
        return;
    }

    char szChunkPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szChunkPath, sizeof(szChunkPath), "data/ad_chunk.bin");
    if (!UTIL_MakeChunk(szDemoSource, szChunkPath, iChunkId, g_iChunkSize))
    {
        // TODO: delete all demo chunks from web? or try again create later?
        hTask.Close();
        return;
    }

    // Rewrite in task all data.
    hTask.Reset(true);
    hTask.WriteString(szDemoId);
    hTask.WriteString(szFullPath);
    hTask.WriteCell(iChunkId + 1);
    hTask.WriteCell(iChunkCount);

    // TODO: рефакторинг запроса под веб
    HTTPRequest hRequest = new HTTPRequest(g_szRemoteUrl);
    hRequest.AppendQueryParam("key", g_szSecretKey);
    hRequest.AppendQueryParam("operation", "upload");
    hRequest.AppendQueryParam("demo_id", szDemoId);
    hRequest.UploadFile(szChunkPath, OnChunkUploaded, hTask);
}

void FinishTask(const char[] szDemoId)
{
    char szJsonPath[PLATFORM_MAX_PATH];
    int iPos = DemoRec_GetDataDirectory(szJsonPath, sizeof(szJsonPath));
    FormatEx(szJsonPath[iPos], sizeof(szJsonPath)-iPos, "/%s.json", szDemoId);

    JSONObject hRequestBody = JSONObject.FromFile(szJsonPath);

    // TODO: рефакторинг запроса под веб
    HTTPRequest hRequest = new HTTPRequest(g_szRemoteUrl);
    hRequest.AppendQueryParam("key", g_szSecretKey);
    hRequest.AppendQueryParam("operation", "finish");
    hRequest.Post(hRequestBody, OnDemoCreated);
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
        LogError("Received unexpected HTTP status: %d", hResponse.Status);
        return;
    }

    g_iChunkSize = (view_as<JSONObject>(hResponse.Data)).GetInt("chunk_size") - 1000;
    g_bReady = true;

    LogMessage("[DEBUG] Chunk size - %d bytes", g_iChunkSize);
}

public void OnChunkUploaded(HTTPStatus iStatus, DataPack hTask, const char[] szError)
{
    if (iStatus != HTTPStatus_Created)
    {
        LogError("Couldn't upload chunk: %d (%s)", iStatus, szError);
        hTask.Close();
        return;
    }

    RunTask(hTask);
}

public void OnDemoCreated(HTTPResponse hResponse, any value, const char[] szError)
{
    if (!hResponse)
    {
        LogError("Couldn't create demo in database: %s", szError);
        return;
    }

    if (hResponse.Status != HTTPStatus_Created)
    {
        LogError("Received unexpected HTTP status: %d", hResponse.Status);
        return;
    }

    // Do nothing?
}

stock bool UTIL_MakeChunk(const char[] szSource, const char[] szTarget, int iChunk = 0, int iChunkSize = DEFAULT_CHUNK_SIZE)
{
    File hSource = OpenFile(szSource, "rb");
    File hTarget = OpenFile(szTarget, "wb");
    if (!hSource || !hTarget)
    {
        hSource.Close();
        hTarget.Close();
        return false;
    }

    if (iChunk)
    {
        if (!hSource.Seek(iChunkSize * iChunk, SEEK_SET))
        {
            hSource.Close();
            hTarget.Close();
            return false;
        }
    }

    int buffer[4096];
    int iBytesWritten = 0;
    int iChunkRead = 0;
    do
    {
        iChunkRead = hSource.Read(buffer, UTIL_Min(sizeof(buffer), (iChunkSize - iBytesWritten) / 4), 4);
        hTarget.Write(buffer, iChunkRead, 4);

        iBytesWritten += iChunkRead * 4;
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