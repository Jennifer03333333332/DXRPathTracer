//=================================================================================================
//
//  DXR Path Tracer
//  by MJP
//  http://mynameismjp.wordpress.com/
//
//  All code and content licensed under the MIT license
//
//=================================================================================================

//=================================================================================================
// Includes
//=================================================================================================
#include <DescriptorTables.hlsl>
#include <Constants.hlsl>
#include <Quaternion.hlsl>
#include <BRDF.hlsl>
#include <RayTracing.hlsl>
#include <Sampling.hlsl>

#include "SharedTypes.h"
#include "AppSettings.hlsl"

struct RayTraceConstants
{
    row_major float4x4 InvViewProjection;

    float3 SunDirectionWS;
    float CosSunAngularRadius;
    float3 SunIrradiance;
    float SinSunAngularRadius;
    float3 SunRenderColor;
    uint Padding;
    float3 CameraPosWS;
    uint CurrSampleIdx;
    uint TotalNumPixels;

    uint VtxBufferIdx;
    uint IdxBufferIdx;
    uint GeometryInfoBufferIdx;
    uint MaterialBufferIdx;
    uint SkyTextureIdx;
    uint NumLights;
};

struct LightConstants
{
    SpotLight Lights[MaxSpotLights];
    float4x4 ShadowMatrices[MaxSpotLights];
};

RaytracingAccelerationStructure Scene : register(t0, space200);
RWTexture2D<float4> RenderTarget : register(u0);

ConstantBuffer<RayTraceConstants> RayTraceCB : register(b0);

ConstantBuffer<LightConstants> LightCBuffer : register(b1);

SamplerState MeshSampler : register(s0);
SamplerState LinearSampler : register(s1);

typedef BuiltInTriangleIntersectionAttributes HitAttributes;
struct PrimaryPayload
{
    float3 Radiance;
    float Roughness;
    uint PathLength;
    uint PixelIdx;
    uint SampleSetIdx;
    bool IsDiffuse;
};

struct ShadowPayload
{
    float Visibility;
};

enum RayTypes {
    RayTypeRadiance = 0,
    RayTypeShadow = 1,

    NumRayTypes
};

static float2 SamplePoint(in uint pixelIdx, inout uint setIdx)
{
    const uint permutation = setIdx * RayTraceCB.TotalNumPixels + pixelIdx;
    setIdx += 1;
    return SampleCMJ2D(RayTraceCB.CurrSampleIdx, AppSettings.SqrtNumSamples, AppSettings.SqrtNumSamples, permutation);
}

[shader("raygeneration")]
void RaygenShader()
{
    const uint2 pixelCoord = DispatchRaysIndex().xy;
    const uint pixelIdx = pixelCoord.y * DispatchRaysDimensions().x + pixelCoord.x;

    uint sampleSetIdx = 0;

    // Form a primary ray by un-projecting the pixel coordinate using the inverse view * projection matrix
    //float2 primaryRaySample = SamplePoint(pixelIdx, sampleSetIdx);

    float2 rayPixelPos = pixelCoord; //+ primaryRaySample;
    float2 ncdXY = (rayPixelPos / (DispatchRaysDimensions().xy * 0.5f)) - 1.0f;
    ncdXY.y *= -1.0f;
    float4 rayStart = mul(float4(ncdXY, 0.0f, 1.0f), RayTraceCB.InvViewProjection);
    float4 rayEnd = mul(float4(ncdXY, 1.0f, 1.0f), RayTraceCB.InvViewProjection);

    rayStart.xyz /= rayStart.w;
    rayEnd.xyz /= rayEnd.w;
    float3 rayDir = normalize(rayEnd.xyz - rayStart.xyz);
    float rayLength = length(rayEnd.xyz - rayStart.xyz);

    // Trace a primary ray
    RayDesc ray;
    ray.Origin = rayStart.xyz;
    ray.Direction = rayDir;
    ray.TMin = 0.0f;
    ray.TMax = rayLength;

    PrimaryPayload payload;
    payload.Radiance = 0.0f;
    payload.Roughness = 0.0f;
    payload.PathLength = 1;
    payload.PixelIdx = pixelIdx;
    payload.SampleSetIdx = sampleSetIdx;
    payload.IsDiffuse = false;

    uint traceRayFlags = 0;

    // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
    if(payload.PathLength > AppSettings.MaxAnyHitPathLength)
        traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

    const uint hitGroupOffset = RayTypeRadiance;
    const uint hitGroupGeoMultiplier = NumRayTypes;
    const uint missShaderIdx = RayTypeRadiance;
    TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

    payload.Radiance = clamp(payload.Radiance, 0.0f, FP16Max);

    // Update the progressive result with the new radiance sample
    //const float lerpFactor = RayTraceCB.CurrSampleIdx / (RayTraceCB.CurrSampleIdx + 1.0f);
    //float3 newSample = payload.Radiance;
    //float3 currValue = RenderTarget[pixelCoord].xyz;
    float3 newValue = payload.Radiance;//lerp(newSample, currValue, lerpFactor);

    RenderTarget[pixelCoord] = float4(newValue, 1.0f);
}


/////////////////////////////////////////////////////////
// Generates a seed for a random number generator from 2 inputs plus a backoff
uint initRand(uint val0, uint val1, uint backoff = 16)
{
    uint v0 = val0, v1 = val1, s0 = 0;

    [unroll]
    for (uint n = 0; n < backoff; n++)
    {
        s0 += 0x9e3779b9;
        v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
        v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
    }
    return v0;
}
// Takes our seed, updates it, and returns a pseudorandom float in [0..1]
float nextRand(inout uint s)
{
    s = (1664525u * s + 1013904223u);
    return float(s & 0x00FFFFFF) / float(0x01000000);
}
// energy uses radiance as unit, such that for point lights it is already divided by squaredDistance.
float evalP(float3 toLight, float3 diffuse, float3 energy, float3 nor) {
    float lambert = saturate(dot(toLight, nor));
    float3 brdf = diffuse / 3.1415926535898f;
    float3 color = brdf * energy * lambert;
    return length(color);
}
// The output textures, where we store our G-buffer results.  See bindings in C++ code.
RWTexture2D<float4> gWsPos;
RWTexture2D<float4> gWsNorm;
RWTexture2D<float4> gMatDif;

// Reservoir texture
RWTexture2D<float4> emittedLight; // xyz: light color
RWTexture2D<float4> toSample; // xyz: hit point(ref) to sample // w: distToLight
RWTexture2D<float4> sampleNormalArea; // xyz: sample noraml // w: area of light
RWTexture2D<float4> reservoir; // x: W // y: Wsum // zw: not used
RWTexture2D<int> M;

void updateReservoir(uint2 launchIndex, float3 Le, float4 toS, float4 sNA, float w, inout uint seed) {
    reservoir[launchIndex].y = reservoir[launchIndex].y + w; // Wsum += w
    M[launchIndex] = M[launchIndex] + 1;
    reservoir[launchIndex].z += 1.f;
    float Wsum = reservoir[launchIndex].y;
    if (Wsum > 0 && nextRand(seed) < (w / Wsum)) {
        emittedLight[launchIndex] = float4(Le, 1.f);
        toSample[launchIndex] = toS;
        sampleNormalArea[launchIndex] = sNA;
    }
}

static float3 PathTraceWithReSTIR(in MeshVertex hitSurface, in Material material, in PrimaryPayload inPayload)
{
    
    

    if ((!AppSettings.EnableDiffuse && !AppSettings.EnableSpecular) ||
        (!AppSettings.EnableDirect && !AppSettings.EnableIndirect))
        return 0.0.xxx;

    if (inPayload.PathLength > 1 && !AppSettings.EnableIndirect)
        return 0.0.xxx;

    float3x3 tangentToWorld = float3x3(hitSurface.Tangent, hitSurface.Bitangent, hitSurface.Normal);

    const float3 positionWS = hitSurface.Position;

    //ReSTIR
    //float depthW = abs(dot(normalize(gCamera.cameraW), positionWS - RayTraceCB.CameraPosWS));


    const float3 incomingRayOriginWS = WorldRayOrigin();
    const float3 incomingRayDirWS = WorldRayDirection();

    float3 normalWS = hitSurface.Normal;
    //delete normal map here
    float3 baseColor = 1.0f;
    if (AppSettings.EnableAlbedoMaps && !AppSettings.EnableWhiteFurnaceMode)//albedo: base color
    {
        Texture2D albedoMap = ResourceDescriptorHeap[material.Albedo];
        baseColor = albedoMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).xyz;//Anisotropic sample
    }
    
    Texture2D metallicMap = ResourceDescriptorHeap[material.Metallic];
    const float metallic = saturate((AppSettings.EnableWhiteFurnaceMode ? 1.0f : metallicMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x) * AppSettings.MetallicScale);

    const bool enableDiffuse = (AppSettings.EnableDiffuse && metallic < 1.0f) || AppSettings.EnableWhiteFurnaceMode;
    const bool enableSpecular = (AppSettings.EnableSpecular && (AppSettings.EnableIndirectSpecular ? !(AppSettings.AvoidCausticPaths && inPayload.IsDiffuse) : (inPayload.PathLength == 1)));

    if (enableDiffuse == false && enableSpecular == false)
        return 0.0f;

    Texture2D roughnessMap = ResourceDescriptorHeap[material.Roughness];
    const float sqrtRoughness = saturate((AppSettings.EnableWhiteFurnaceMode ? 1.0f : roughnessMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x) * AppSettings.RoughnessScale);

    const float3 diffuseAlbedo = lerp(baseColor, 0.0f, metallic) * (enableDiffuse ? 1.0f : 0.0f);
    const float3 specularAlbedo = lerp(0.03f, baseColor, metallic) * (enableSpecular ? 1.0f : 0.0f);
    float roughness = sqrtRoughness * sqrtRoughness;
    if (AppSettings.ClampRoughness)
        roughness = max(roughness, inPayload.Roughness);

    float3 msEnergyCompensation = 1.0.xxx;//means(1.0,1.0,1.0)

    Texture2D emissiveMap = ResourceDescriptorHeap[material.Emissive];
    float3 radiance = AppSettings.EnableWhiteFurnaceMode ? 0.0.xxx : emissiveMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).xyz;

    //Apply sun light
    if (AppSettings.EnableSun && !AppSettings.EnableWhiteFurnaceMode)
    {
        float3 sunDirection = RayTraceCB.SunDirectionWS;
        //delete SunAreaLightApproximation

        // Shoot a shadow ray to see if the sun is occluded
        RayDesc ray;
        ray.Origin = positionWS;
        ray.Direction = RayTraceCB.SunDirectionWS;
        ray.TMin = 0.00001f;
        ray.TMax = FP32Max;

        ShadowPayload payload;
        payload.Visibility = 1.0f;

        uint traceRayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (inPayload.PathLength > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeShadow;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeShadow;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        radiance += CalcLighting(normalWS, sunDirection, RayTraceCB.SunIrradiance, diffuseAlbedo, specularAlbedo,
            roughness, positionWS, incomingRayOriginWS, msEnergyCompensation) * payload.Visibility;
    }

    // delete RenderLights
    
    // Choose our next path by importance sampling our BRDFs
    float2 brdfSample = SamplePoint(inPayload.PixelIdx, inPayload.SampleSetIdx);

    float3 throughput = 0.0f;
    float3 rayDirTS = 0.0f;

    //delete enableSpecular and BRDF
    float selector = brdfSample.x;

    // We're sampling the diffuse BRDF, so sample a cosine-weighted hemisphere
    if (enableSpecular)
        brdfSample.x *= 2.0f;
    rayDirTS = SampleDirectionCosineHemisphere(brdfSample.x, brdfSample.y);

    // The PDF of sampling a cosine hemisphere is NdotL / Pi, which cancels out those terms
    // from the diffuse BRDF and the irradiance integral
    throughput = diffuseAlbedo;

    const float3 rayDirWS = normalize(mul(rayDirTS, tangentToWorld));

    if (enableDiffuse && enableSpecular)
        throughput *= 2.0f;

    // Shoot another ray to get the next path
    RayDesc ray;
    ray.Origin = positionWS;
    ray.Direction = rayDirWS;
    ray.TMin = 0.00001f;
    ray.TMax = FP32Max;

    if (inPayload.PathLength == 1 && !AppSettings.EnableDirect)
        radiance = 0.0.xxx;

    if (AppSettings.EnableIndirect && (inPayload.PathLength + 1 < AppSettings.MaxPathLength) && !AppSettings.EnableWhiteFurnaceMode)
    {
        PrimaryPayload payload;
        payload.Radiance = 0.0f;
        payload.PathLength = inPayload.PathLength + 1;
        payload.PixelIdx = inPayload.PixelIdx;
        payload.SampleSetIdx = inPayload.SampleSetIdx;
        payload.IsDiffuse = (selector < 0.5f);
        payload.Roughness = roughness;

        uint traceRayFlags = 0;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (payload.PathLength > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeRadiance;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeRadiance;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        radiance += payload.Radiance * throughput;
    }
    else
    {
        ShadowPayload payload;
        payload.Visibility = 1.0f;

        uint traceRayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (inPayload.PathLength + 1 > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeShadow;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeShadow;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        if (AppSettings.EnableWhiteFurnaceMode)
        {
            radiance = throughput;
        }
        else//for sky
        {
            TextureCube skyTexture = TexCubeTable[RayTraceCB.SkyTextureIdx];
            float3 skyRadiance = AppSettings.EnableSky ? skyTexture.SampleLevel(LinearSampler, rayDirWS, 0.0f).xyz : 0.0.xxx;

            radiance += payload.Visibility * skyRadiance * throughput;
        }
    }

    return radiance;
}

static float3 PathTraceWithoutReSTIR(in MeshVertex hitSurface, in Material material, in PrimaryPayload inPayload)
{
    if ((!AppSettings.EnableDiffuse && !AppSettings.EnableSpecular) ||
        (!AppSettings.EnableDirect && !AppSettings.EnableIndirect))
        return 0.0.xxx;

    if (inPayload.PathLength > 1 && !AppSettings.EnableIndirect)
        return 0.0.xxx;

    float3x3 tangentToWorld = float3x3(hitSurface.Tangent, hitSurface.Bitangent, hitSurface.Normal);

    const float3 positionWS = hitSurface.Position;

    const float3 incomingRayOriginWS = WorldRayOrigin();
    const float3 incomingRayDirWS = WorldRayDirection();

    float3 normalWS = hitSurface.Normal;
    //delete normal map here
    float3 baseColor = 1.0f;
    if (AppSettings.EnableAlbedoMaps && !AppSettings.EnableWhiteFurnaceMode)//albedo: base color
    {
        Texture2D albedoMap = ResourceDescriptorHeap[material.Albedo];
        baseColor = albedoMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).xyz;//Anisotropic sample
    }

    Texture2D metallicMap = ResourceDescriptorHeap[material.Metallic];
    const float metallic = saturate((AppSettings.EnableWhiteFurnaceMode ? 1.0f : metallicMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x) * AppSettings.MetallicScale);

    const bool enableDiffuse = (AppSettings.EnableDiffuse && metallic < 1.0f) || AppSettings.EnableWhiteFurnaceMode;
    const bool enableSpecular = (AppSettings.EnableSpecular && (AppSettings.EnableIndirectSpecular ? !(AppSettings.AvoidCausticPaths && inPayload.IsDiffuse) : (inPayload.PathLength == 1)));

    if (enableDiffuse == false && enableSpecular == false)
        return 0.0f;

    Texture2D roughnessMap = ResourceDescriptorHeap[material.Roughness];
    const float sqrtRoughness = saturate((AppSettings.EnableWhiteFurnaceMode ? 1.0f : roughnessMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x) * AppSettings.RoughnessScale);

    const float3 diffuseAlbedo = lerp(baseColor, 0.0f, metallic) * (enableDiffuse ? 1.0f : 0.0f);
    const float3 specularAlbedo = lerp(0.03f, baseColor, metallic) * (enableSpecular ? 1.0f : 0.0f);
    float roughness = sqrtRoughness * sqrtRoughness;
    if (AppSettings.ClampRoughness)
        roughness = max(roughness, inPayload.Roughness);

    float3 msEnergyCompensation = 1.0.xxx;//means(1.0,1.0,1.0)

    Texture2D emissiveMap = ResourceDescriptorHeap[material.Emissive];
    float3 radiance = AppSettings.EnableWhiteFurnaceMode ? 0.0.xxx : emissiveMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).xyz;

    //Apply sun light
    if (AppSettings.EnableSun && !AppSettings.EnableWhiteFurnaceMode)
    {
        float3 sunDirection = RayTraceCB.SunDirectionWS;
        //delete SunAreaLightApproximation

        // Shoot a shadow ray to see if the sun is occluded
        RayDesc ray;
        ray.Origin = positionWS;
        ray.Direction = RayTraceCB.SunDirectionWS;
        ray.TMin = 0.00001f;
        ray.TMax = FP32Max;

        ShadowPayload payload;
        payload.Visibility = 1.0f;

        uint traceRayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (inPayload.PathLength > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeShadow;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeShadow;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        radiance += CalcLighting(normalWS, sunDirection, RayTraceCB.SunIrradiance, diffuseAlbedo, specularAlbedo,
            roughness, positionWS, incomingRayOriginWS, msEnergyCompensation) * payload.Visibility;
    }

    // delete RenderLights

    // Choose our next path by importance sampling our BRDFs
    float2 brdfSample = SamplePoint(inPayload.PixelIdx, inPayload.SampleSetIdx);

    float3 throughput = 0.0f;
    float3 rayDirTS = 0.0f;

    //delete enableSpecular and BRDF
    float selector = brdfSample.x;

    // We're sampling the diffuse BRDF, so sample a cosine-weighted hemisphere
    if (enableSpecular)
        brdfSample.x *= 2.0f;
    rayDirTS = SampleDirectionCosineHemisphere(brdfSample.x, brdfSample.y);

    // The PDF of sampling a cosine hemisphere is NdotL / Pi, which cancels out those terms
    // from the diffuse BRDF and the irradiance integral
    throughput = diffuseAlbedo;

    const float3 rayDirWS = normalize(mul(rayDirTS, tangentToWorld));

    if (enableDiffuse && enableSpecular)
        throughput *= 2.0f;

    // Shoot another ray to get the next path
    RayDesc ray;
    ray.Origin = positionWS;
    ray.Direction = rayDirWS;
    ray.TMin = 0.00001f;
    ray.TMax = FP32Max;

    if (inPayload.PathLength == 1 && !AppSettings.EnableDirect)
        radiance = 0.0.xxx;

    if (AppSettings.EnableIndirect && (inPayload.PathLength + 1 < AppSettings.MaxPathLength) && !AppSettings.EnableWhiteFurnaceMode)
    {
        PrimaryPayload payload;
        payload.Radiance = 0.0f;
        payload.PathLength = inPayload.PathLength + 1;
        payload.PixelIdx = inPayload.PixelIdx;
        payload.SampleSetIdx = inPayload.SampleSetIdx;
        payload.IsDiffuse = (selector < 0.5f);
        payload.Roughness = roughness;

        uint traceRayFlags = 0;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (payload.PathLength > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeRadiance;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeRadiance;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        radiance += payload.Radiance * throughput;
    }
    else
    {
        ShadowPayload payload;
        payload.Visibility = 1.0f;

        uint traceRayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;

        // Stop using the any-hit shader once we've hit the max path length, since it's *really* expensive
        if (inPayload.PathLength + 1 > AppSettings.MaxAnyHitPathLength)
            traceRayFlags = RAY_FLAG_FORCE_OPAQUE;

        const uint hitGroupOffset = RayTypeShadow;
        const uint hitGroupGeoMultiplier = NumRayTypes;
        const uint missShaderIdx = RayTypeShadow;
        TraceRay(Scene, traceRayFlags, 0xFFFFFFFF, hitGroupOffset, hitGroupGeoMultiplier, missShaderIdx, ray, payload);

        if (AppSettings.EnableWhiteFurnaceMode)
        {
            radiance = throughput;
        }
        else//for sky
        {
            TextureCube skyTexture = TexCubeTable[RayTraceCB.SkyTextureIdx];
            float3 skyRadiance = AppSettings.EnableSky ? skyTexture.SampleLevel(LinearSampler, rayDirWS, 0.0f).xyz : 0.0.xxx;

            radiance += payload.Visibility * skyRadiance * throughput;
        }
    }

    return radiance;
}

// Loops up the vertex data for the hit triangle and interpolates its attributes
MeshVertex GetHitSurface(in HitAttributes attr, in uint geometryIdx)
{
    float3 barycentrics = float3(1 - attr.barycentrics.x - attr.barycentrics.y, attr.barycentrics.x, attr.barycentrics.y);

    StructuredBuffer<GeometryInfo> geoInfoBuffer = ResourceDescriptorHeap[RayTraceCB.GeometryInfoBufferIdx];
    const GeometryInfo geoInfo = geoInfoBuffer[geometryIdx];

    StructuredBuffer<MeshVertex> vtxBuffer = ResourceDescriptorHeap[RayTraceCB.VtxBufferIdx];
    Buffer<uint> idxBuffer = ResourceDescriptorHeap[RayTraceCB.IdxBufferIdx];

    const uint primIdx = PrimitiveIndex();
    const uint idx0 = idxBuffer[primIdx * 3 + geoInfo.IdxOffset + 0];
    const uint idx1 = idxBuffer[primIdx * 3 + geoInfo.IdxOffset + 1];
    const uint idx2 = idxBuffer[primIdx * 3 + geoInfo.IdxOffset + 2];

    const MeshVertex vtx0 = vtxBuffer[idx0 + geoInfo.VtxOffset];
    const MeshVertex vtx1 = vtxBuffer[idx1 + geoInfo.VtxOffset];
    const MeshVertex vtx2 = vtxBuffer[idx2 + geoInfo.VtxOffset];

    return BarycentricLerp(vtx0, vtx1, vtx2, barycentrics);
}

// Gets the material assigned to a geometry in the acceleration structure
Material GetGeometryMaterial(in uint geometryIdx)
{
    StructuredBuffer<GeometryInfo> geoInfoBuffer = ResourceDescriptorHeap[RayTraceCB.GeometryInfoBufferIdx];
    const GeometryInfo geoInfo = geoInfoBuffer[geometryIdx];

    StructuredBuffer<Material> materialBuffer = ResourceDescriptorHeap[RayTraceCB.MaterialBufferIdx];
    return materialBuffer[geoInfo.MaterialIdx];
}

[shader("closesthit")]
void ClosestHitShader(inout PrimaryPayload payload, in HitAttributes attr)
{
    const MeshVertex hitSurface = GetHitSurface(attr, GeometryIndex());
    const Material material = GetGeometryMaterial(GeometryIndex());

    payload.Radiance = PathTraceWithReSTIR(hitSurface, material, payload);//PathTrace()
}

//No transparent now
[shader("anyhit")]
void AnyHitShader(inout PrimaryPayload payload, in HitAttributes attr)
{
    //const MeshVertex hitSurface = GetHitSurface(attr, GeometryIndex());
    //const Material material = GetGeometryMaterial(GeometryIndex());

    //// Standard alpha testing
    //Texture2D opacityMap = ResourceDescriptorHeap[material.Opacity];
    //if(opacityMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x < 0.35f)
    //    IgnoreHit();
}

[shader("anyhit")]
void ShadowAnyHitShader(inout ShadowPayload payload, in HitAttributes attr)
{
    //const MeshVertex hitSurface = GetHitSurface(attr, GeometryIndex());
    //const Material material = GetGeometryMaterial(GeometryIndex());

    //// Standard alpha testing
    //Texture2D opacityMap = ResourceDescriptorHeap[material.Opacity];
    //if(opacityMap.SampleLevel(MeshSampler, hitSurface.UV, 0.0f).x < 0.35f)
    //    IgnoreHit();
}

[shader("miss")]
void MissShader(inout PrimaryPayload payload)
{
    if(AppSettings.EnableWhiteFurnaceMode)
    {
        payload.Radiance = 1.0.xxx;
    }
    else
    {
        const float3 rayDir = WorldRayDirection();

        TextureCube skyTexture = ResourceDescriptorHeap[RayTraceCB.SkyTextureIdx];
        payload.Radiance = AppSettings.EnableSky ? skyTexture.SampleLevel(LinearSampler, rayDir, 0.0f).xyz : 0.0.xxx;

        if(payload.PathLength == 1)
        {
            float cosSunAngle = dot(rayDir, RayTraceCB.SunDirectionWS);
            if(cosSunAngle >= RayTraceCB.CosSunAngularRadius)
                payload.Radiance = RayTraceCB.SunRenderColor;
        }
    }
}

[shader("closesthit")]
void ShadowHitShader(inout ShadowPayload payload, in HitAttributes attr)
{
    payload.Visibility = 0.0f;
}

[shader("miss")]
void ShadowMissShader(inout ShadowPayload payload)
{
    payload.Visibility = 1.0f;
}