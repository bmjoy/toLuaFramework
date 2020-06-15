﻿#ifndef EASYRP_LIT_INCLUDED
#define EASYRP_LIT_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"

CBUFFER_START(UnityPerFrame)
	float4x4 unity_MatrixVP;
CBUFFER_END
CBUFFER_START(UnityPerDraw)
	float4x4 unity_ObjectToWorld;
	float4x4 unity_WorldToObject; 
	float4 unity_LODFade;
	real4 unity_WorldTransformParams;
	float4 unity_LightData; // Y分量存有当前物体受多少光源影响的数量。
	real4 unity_LightIndices[2];
CBUFFER_END
// 光源缓冲区
#define MAX_VISIBLE_LIGHTS 16
CBUFFER_START(_LightBuffer)
	float4 _VisibleLightColors[MAX_VISIBLE_LIGHTS];
	float4 _VisibleLightDirectionsOrPositions[MAX_VISIBLE_LIGHTS];
	float4 _VisibleLightAttenuations[MAX_VISIBLE_LIGHTS];
	float4 _VisibleLightSpotDirections[MAX_VISIBLE_LIGHTS];
CBUFFER_END

float3 DiffuseLight(int index, float3 normal, float3 worldPos, float shadowAttenuation) {
	float3 lightColor = _VisibleLightColors[index].rgb;
	float4 lightPositionOrDirection = _VisibleLightDirectionsOrPositions[index];
	float4 lightAttenuation = _VisibleLightAttenuations[index];
	// 当是方向光时，w是0，当是点光源时，w是1，我们利用该性质将 worldPos 与 w 分量相乘，这样就可以用同一个公式计算点光源和方向光的信息。
	float3 lightVector = lightPositionOrDirection.xyz - worldPos * lightPositionOrDirection.w;
	float3 lightDirection = normalize(lightVector);
	float3 spotDirection = _VisibleLightSpotDirections[index].xyz;
	float diffuse = saturate(dot(normal, lightDirection));
	// 和方向光不同，点光源要考虑光源强度随着距离而衰减。这里的衰减关系是距离平方的倒数。为了避免除数是0出现错误，因此加入一个极小的值0.00001。
	float distanceSqr = max(dot(lightVector, lightVector), 0.00001);
	// 点光源还需要考虑光照范围。
	float rangeFade = dot(lightVector, lightVector) * lightAttenuation.x;
	rangeFade = saturate(1.0 - rangeFade * rangeFade);
	rangeFade *= rangeFade;
	// 聚光灯的衰减。
	float spotFade = dot(spotDirection, lightDirection);
	spotFade = saturate(spotFade * lightAttenuation.z + lightAttenuation.w);
	spotFade *= spotFade;

	diffuse *= shadowAttenuation * spotFade * rangeFade / distanceSqr;
	return diffuse * lightColor;
}

// 阴影缓冲区
CBUFFER_START(_ShadowBuffer)
	float4x4 _WorldToShadowMatrices[MAX_VISIBLE_LIGHTS];
	float4x4 _WorldToShadowCascadeMatrices[4];
	float4 _CascadeCullingSpheres[4];
	float4 _ShadowData[MAX_VISIBLE_LIGHTS];
	float4 _ShadowMapSize;
	float4 _CascadedShadowMapSize;
	float4 _GlobalShadowData;
	float _CascadedShadowStrength;
CBUFFER_END

TEXTURE2D_SHADOW(_ShadowMap); // 定义阴影纹理
SAMPLER_CMP(sampler_ShadowMap); // 定义阴影采样器状态

TEXTURE2D_SHADOW(_CascadedShadowMap); // 定义主光源级联阴影纹理
SAMPLER_CMP(sampler_CascadedShadowMap); // 定义主光源级联阴影采样器状态

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Shadow/ShadowSamplingTent.hlsl" // 软阴影采样（SampleShadow_ComputeSamples_Tent_5x5）需要。

float HardShadowAttenuation(float4 shadowPos, bool cascade = false)
{
	// 通过 SAMPLE_TEXTURE2D_SHADOW 这个宏采样阴影贴图。它需要一张贴图，一个采样器状态，以及对应的阴影空间位置作为参数。
	// 如果该点位置的z值比在阴影贴图中对应点的值要小就会返回1，这说明他比任何投射阴影的物体离光源都要近。
	// 反之，在阴影投射物后面就会返回0。因为采样器会在双线性插值之前先进行比较，所以阴影边缘会混合阴影贴图的多个纹素（texels）。
	if (cascade) {
		return SAMPLE_TEXTURE2D_SHADOW(_CascadedShadowMap, sampler_CascadedShadowMap, shadowPos.xyz);
	} else {
		return SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowPos.xyz);
	}
}

float SoftShadowAttenuation(float4 shadowPos, bool cascade = false)
{
	real tentWeights[9]; // real不是一个实际的数字类型，而是一个宏，根据需要自动选择float或者half。
	real2 tentUVs[9];
	float4 size = cascade ? _CascadedShadowMapSize : _ShadowMapSize;
	SampleShadow_ComputeSamples_Tent_5x5(size, shadowPos.xy, tentWeights, tentUVs);
	float attenuation = 0;
	for (int i = 0; i < 9; i++) {
		attenuation += tentWeights[i] * HardShadowAttenuation(float4(tentUVs[i].xy, shadowPos.z, 0), cascade);
	}
	return attenuation;
}

CBUFFER_START(UnityPerCamera) // UnityPerCamera 缓冲区会提供相机位置信息。
	float3 _WorldSpaceCameraPos;
CBUFFER_END

float DistanceToCameraSqr(float3 worldPos) 
{
	float3 cameraToFragment = worldPos - _WorldSpaceCameraPos;
	return dot(cameraToFragment, cameraToFragment);
}

float ShadowAttenuation(int index, float3 worldPos)
{
#if !defined(_RECEIVE_SHADOWS)
	return 1.0;
#elif !defined(_SHADOWS_HARD) && !defined(_SHADOWS_SOFT)
	return 1.0;
#endif
	if (_ShadowData[index].x <= 0 || DistanceToCameraSqr(worldPos) > _GlobalShadowData.y) {
		return 1.0;
	}
	float4 shadowPos = mul(_WorldToShadowMatrices[index], float4(worldPos, 1.0));
	// 从齐次坐标转换到常规坐标。
	shadowPos.xyz /= shadowPos.w;
	// 在透视除法后对阴影位置的xy坐标做限制，将其限制在0-1范围内，确保阴影采样坐标在tile内。
	shadowPos.xy = saturate(shadowPos.xy);
	shadowPos.xy = shadowPos.xy * _GlobalShadowData.x + _ShadowData[index].zw;
	float attenuation;
#if defined(_SHADOWS_HARD)
	#if defined(_SHADOWS_SOFT)
		if (_ShadowData[index].y == 0) {
			attenuation = HardShadowAttenuation(shadowPos);
		}
		else
		{
			attenuation = SoftShadowAttenuation(shadowPos);
		}
	#else
		attenuation = HardShadowAttenuation(shadowPos);
	#endif
#else
	attenuation = SoftShadowAttenuation(shadowPos);
#endif

	return lerp(1, attenuation, _ShadowData[index].x);
}

// 判断一个点是否在剔除球体内。
float InsideCascadeCullingSphere(int index, float3 worldPos) 
{
	float4 s = _CascadeCullingSpheres[index];
	return dot(worldPos - s.xyz, worldPos - s.xyz) < s.w;
}

float CascadedShadowAttenuation(float3 worldPos) 
{
#if !defined(_RECEIVE_SHADOWS)
	return 1.0;
#elif !defined(_CASCADED_SHADOWS_HARD) && !defined(_CASCADED_SHADOWS_SOFT)
	return 1.0;
#endif
	// 因为剔除球不会与相机和阴影距离对齐，所以级联阴影不会和其他阴影一样在同一距离消失。
	// 我们也一样可以在 CascadedShadowAttenuation 中检查阴影距离来实现统一的效果。
	if (DistanceToCameraSqr(worldPos) > _GlobalShadowData.y) {
		return 1.0;
	}
	// 一点位于一个球的同时，还在更大的球里面。
	// 我们最终可能得到五种情况： (1,1,1,1)，(0,1,1,1)，(0,0,1,1)，(0,0,0,1)，(0,0,0,0)。
	float4 cascadeFlags = float4(
		InsideCascadeCullingSphere(0, worldPos),
		InsideCascadeCullingSphere(1, worldPos),
		InsideCascadeCullingSphere(2, worldPos),
		InsideCascadeCullingSphere(3, worldPos)
	);
	//return dot(cascadeFlags, 0.25); // 可以用来观察级联层次。
	cascadeFlags.yzw = saturate(cascadeFlags.yzw - cascadeFlags.xyz);
	float cascadeIndex = 4 - dot(cascadeFlags, float4(4, 3, 2, 1));
	if (cascadeIndex == 4) { // 在所有级联阴影贴图之外，直接忽略。
		return 1.0; 
	}
	float4 shadowPos = mul(_WorldToShadowCascadeMatrices[cascadeIndex], float4(worldPos, 1.0));
	float attenuation;
#if defined(_CASCADED_SHADOWS_HARD)
	attenuation = HardShadowAttenuation(shadowPos, true);
#else
	attenuation = SoftShadowAttenuation(shadowPos, true);
#endif
	return lerp(1, attenuation, _CascadedShadowStrength);
}

float3 MainLight(float3 normal, float3 worldPos) 
{
	float shadowAttenuation = CascadedShadowAttenuation(worldPos);
	float3 lightColor = _VisibleLightColors[0].rgb;
	float3 lightDirection = _VisibleLightDirectionsOrPositions[0].xyz;
	float diffuse = saturate(dot(normal, lightDirection));
	diffuse *= shadowAttenuation;
	return diffuse * lightColor;
}

#define UNITY_MATRIX_M unity_ObjectToWorld
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl" 

CBUFFER_START(UnityPerMaterial)
	float4 _MainTex_ST;
	float4 _Color;
	float _Cutoff;
CBUFFER_END
#if defined(UNITY_INSTANCING_ENABLED)
UNITY_INSTANCING_BUFFER_START(UnityPerMaterial)
	UNITY_DEFINE_INSTANCED_PROP(float4, _Color)
UNITY_INSTANCING_BUFFER_END(PerInstance)
#endif

TEXTURE2D(_MainTex);
SAMPLER(sampler_MainTex);

struct VertexInput
{
	float4 pos				: POSITION;
	float3 normal			: NORMAL;
	float2 uv				: TEXCOORD0;
	UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct VertexOutput
{
	float4 clipPos			: SV_POSITION;
	float3 normal			: TEXCOORD0;
	float3 worldPos			: TEXCOORD1;
	float3 vertexLighting	: TEXCOORD2;
	float2 uv				: TEXCOORD3;
	UNITY_VERTEX_INPUT_INSTANCE_ID
};

VertexOutput LitPassVertex(VertexInput input)
{
	VertexOutput output;
	UNITY_SETUP_INSTANCE_ID(input);
	UNITY_TRANSFER_INSTANCE_ID(input, output);
	float4 worldPos = mul(UNITY_MATRIX_M, float4(input.pos.xyz, 1.0));
	output.clipPos = mul(unity_MatrixVP, worldPos);
	output.uv = TRANSFORM_TEX(input.uv, _MainTex);
	output.normal = mul(transpose((float3x3)unity_WorldToObject), input.normal);
	//output.normal = mul((float3x3)UNITY_MATRIX_M, input.normal); // 如果物体使用统一的scale，可以考虑使用 3X3 模型矩阵简化法线的坐标变换。
	output.worldPos = worldPos.xyz;
	// 由于后四个光源其实并没有那么重要，我们可以将其计算从fragment函数中移到vertex函数中，也就是从逐像素光照改为逐顶点光照，
	// 这样虽然着色的精度会损失一些，但是可以减少GPU的消耗。
	output.vertexLighting = 0;
	for (int i = 4; i < min(unity_LightData.y, 8); i++) { // unity_LightIndices[1] 只能存储4个值。
		int lightIndex = unity_LightIndices[1][i - 4];
		output.vertexLighting += DiffuseLight(lightIndex, input.normal, worldPos.xyz, 1); // 顶点光源现在不会有阴影，所以将阴影衰减值设为1。
	}
	return output;
}

float4 LitPassFragment(VertexOutput input, FRONT_FACE_TYPE isFrontFace : FRONT_FACE_SEMANTIC) : SV_TARGET
{
	UNITY_SETUP_INSTANCE_ID(input);
	float4 albedoAlpha = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);
	albedoAlpha *= UNITY_ACCESS_INSTANCED_PROP(PerInstance, _Color);
	input.normal = normalize(input.normal); // 坐标变换后在fragment函数中进行归一化。
	input.normal = IS_FRONT_VFACE(isFrontFace, input.normal, -input.normal); // 修正只渲染背面时，法线相反的问题。
	float3 diffuseLight = input.vertexLighting;
#if defined(_CASCADED_SHADOWS_HARD) || defined(_CASCADED_SHADOWS_SOFT)
	diffuseLight += MainLight(input.normal, input.worldPos);
#endif
	for (int i = 0; i < min(unity_LightData.y, 4); i++) { // unity_LightIndices[0] 只能存储4个值。
		int lightIndex = unity_LightIndices[0][i];
		float shadowAttenuation = ShadowAttenuation(lightIndex, input.worldPos);
		diffuseLight += DiffuseLight(lightIndex, input.normal, input.worldPos, shadowAttenuation);
	}
	float3 color = diffuseLight * albedoAlpha.rgb;

#if defined(_CLIPPING_ON)
	clip(albedoAlpha.a - _Cutoff); // alpha值小于阈值的片段将被丢弃，不会被渲染。
#endif

	return float4(color, albedoAlpha.a);
}

#endif // EASYRP_LIT_INCLUDED
