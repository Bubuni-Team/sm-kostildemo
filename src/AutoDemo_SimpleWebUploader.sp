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

char    g_szRemoteUrl[256];
char    g_szSecretKey[128];
char    g_szUserAgent[128];
int     g_iChunkSize;
int     g_iMaxSpeed;

ConVar  g_hRemoteUrl;
ConVar  g_hSecretKey;
ConVar  g_hUserAgent;
ConVar  g_hMaxSpeed;

bool    g_bIsPlannedRequestChunkSize;
bool    g_bReady;

public Plugin myinfo = {
    description = "Simple uploader for simple web",
    version = "0.1.0.0",
    author = "Bubuni",
    name = "[AutoDemo] Simple Web Uploader",
    url = "https://github.com/Bubuni-Team"
};

public void OnPluginStart()
{
    g_hRemoteUrl = CreateConVar("sm_autodemo_sdu_url", "", "URL to web installation");
    g_hSecretKey = CreateConVar("sm_autodemo_sdu_key", "", "Secret server key");
    g_hUserAgent = CreateConVar("sm_autodemo_sdu_user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0");
    g_hMaxSpeed = CreateConVar("sm_autodemo_sdu_max_speed", "0", "Max speed for uploading (in bytes per second). 0 means \"no limit\".", _, true, 0.0);
    AutoExecConfig(true, "autodemo_simpleuploader");

    HookConVarChange(g_hRemoteUrl, OnConVarChanged);
    HookConVarChange(g_hSecretKey, OnConVarChanged);
    HookConVarChange(g_hUserAgent, OnConVarChanged);
    HookConVarChange(g_hMaxSpeed, OnConVarChanged);
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
    hTask.WriteString(szDemoSource);
    hTask.WriteCell(iChunkId + 1);
    hTask.WriteCell(iChunkCount);

    HTTPRequest hRequest = MakeRequest("upload", true);
    hRequest.AppendQueryParam("demo_id", szDemoId);
    hRequest.AppendQueryParam("chunk_id", UTIL_IntToString(iChunkId));
    hRequest.UploadFile(szChunkPath, OnChunkUploaded, hTask);
}

void FinishTask(const char[] szDemoId)
{
    char szBasePath[192];
    char szJsonPath[PLATFORM_MAX_PATH];
    DemoRec_GetDataDirectory(szBasePath, sizeof(szBasePath));
    FormatEx(szJsonPath, sizeof(szJsonPath), "%s/%s.json", szBasePath, szDemoId);

    JSONObject hRequestBody = JSONObject.FromFile(szJsonPath);

    MakeRequest("finish").Post(hRequestBody, OnDemoCreated);
    hRequestBody.Close();
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

    g_iChunkSize = (view_as<JSONObject>(hResponse.Data)).GetInt("chunkSize") - 1000;
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

    // Kruzya: Для корректности определения, какого размера файл будет,
    // пересчитаем ChunkSize в зависимости от размера файла.
    //
    // 20.06.2021

    iChunkSize = UTIL_Min(iChunkSize, FileSize(szSource) - (iChunkSize * iChunk));

    int buffer[4096];
    int iBytesWritten = 0;
    int iChunkRead = 0;
    int iBytesPerCell = 4;
    do
    {
        // Kruzya: Проблема в том, что если вычитывать и записывать по 1 байту
        // постоянно, то этот процесс очень тормознуто идёт. Даже обработку
        // тика тормозит.
        //
        // Потому мы пытаемся делать следующий трюк: если нужно прочитать ещё
        // 16384 байт и более, то читаем в ячейку памяти по 4 байта. А если
        // менее 16384 байт - тогда по 1 байту в ячейку. Это должно работать
        // быстро на протяжении 99% файла, и лишь на 1% - подтормаживать.
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
