/* A tiny Direct3D 11 program for the engine smoke test (CI builds it with
 * mingw-w64 and runs it in a bottle). It creates a device, renders one clear
 * into an off-screen texture and reads a pixel back, then reports which
 * Direct3D implementation served it. Exit status: 0 when the pixel is right,
 * 2 when no device could be created, 3 when rendering or read-back failed. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &level, &context);
    printf("probe: D3D11CreateDevice hr=0x%08lx level=0x%04x\n", (unsigned long)hr, (unsigned)level);
    printf("probe: winemetal=%s wined3d=%s dxvk=%s\n",
           GetModuleHandleA("winemetal.dll") ? "loaded" : "absent",
           GetModuleHandleA("wined3d.dll") ? "loaded" : "absent",
           GetModuleHandleA("winevulkan.dll") ? "loaded" : "absent");
    fflush(stdout);
    if (FAILED(hr)) return 2;

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc)))
        printf("probe: adapter=\"%ls\" vendor=0x%04x dedicated=%lluMB shared=%lluMB\n", desc.Description,
               desc.VendorId, (unsigned long long)(desc.DedicatedVideoMemory >> 20),
               (unsigned long long)(desc.SharedSystemMemory >> 20));

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = 64; td.Height = 64; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *target = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &td, NULL, &target)) ||
        FAILED(ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view))) {
        printf("probe: could not create the render target\n");
        return 3;
    }
    const float color[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    ID3D11DeviceContext_ClearRenderTargetView(context, view, color);

    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(ID3D11Device_CreateTexture2D(device, &td, NULL, &staging))) {
        printf("probe: could not create the staging texture\n");
        return 3;
    }
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    D3D11_MAPPED_SUBRESOURCE map;
    hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr)) {
        printf("probe: Map failed hr=0x%08lx\n", (unsigned long)hr);
        return 3;
    }
    const unsigned char *p = (const unsigned char *)map.pData;
    printf("probe: pixel=%u,%u,%u,%u\n", p[0], p[1], p[2], p[3]);
    int ok = p[0] >= 62 && p[0] <= 66 && p[1] >= 126 && p[1] <= 130 && p[2] >= 189 && p[2] <= 193 && p[3] == 255;
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    printf("probe: %s\n", ok ? "rendered" : "wrong pixel");
    fflush(stdout);
    return ok ? 0 : 3;
}
