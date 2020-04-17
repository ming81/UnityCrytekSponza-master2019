//#include "Common.cginc"
#include "ACES.hlsl"
#include "Colors.hlsl"

#if defined(SHADER_API_PSSL)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_XBOXONE)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_D3D11)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_D3D12)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_D3D9) || defined(SHADER_API_D3D11_9X)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_VULKAN)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_SWITCH)
	#define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_METAL)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#elif defined(SHADER_API_PSP2)
    #define UNITY_UV_STARTS_AT_TOP_HlSL 1
#else
    #define UNITY_UV_STARTS_AT_TOP_HlSL 0
#endif


sampler2D 	_UserLutTex;
float4 		_LutParams;
float4 		_UserLutParams;
half 		_Contribution;

sampler2D	_CurveTex;

float3 _WhiteBalance;
float3 _ColorFilter;
float3 _Lift;
float3 _InvGamma;
float3 _Gain;

float3 _HSC;

float3 _ChannelMixerRed;
float3 _ChannelMixerGreen;
float3 _ChannelMixerBlue;

float4 _CustomToneCurve;
float4 _ToeSegmentA;
float4 _ToeSegmentB;
float4 _MidSegmentA;
float4 _MidSegmentB;
float4 _ShoSegmentA;
float4 _ShoSegmentB;

      float3 ApplyCommonGradingSteps(float3 colorLinear)
        {
            colorLinear = WhiteBalance(colorLinear, _WhiteBalance);
			colorLinear *= _ColorFilter;
            colorLinear = ChannelMixer(colorLinear, _ChannelMixerRed, _ChannelMixerGreen, _ChannelMixerBlue);
            colorLinear = LiftGammaGainHDR(colorLinear, _Lift, _InvGamma, _Gain);

            // Do NOT feed negative values to RgbToHsv or they'll wrap around
            colorLinear = max((float3)0.0, colorLinear);

            float3 hsv = RgbToHsv(colorLinear);

            // Hue Vs Sat
            float satMult;
            satMult = saturate(tex2Dlod(_CurveTex,  float4(hsv.x, 0.25,0,0)).y) * 2.0;

            // Sat Vs Sat
            satMult *= saturate(tex2Dlod(_CurveTex,  float4(hsv.y, 0.25,0,0)).z) * 2.0;

            // Lum Vs Sat
            satMult *= saturate(tex2Dlod(_CurveTex,  float4(Luminance2(colorLinear), 0.25,0,0)).w) * 2.0;

            // Hue Vs Hue
            float hue = hsv.x + _HSC.x;
            float offset = saturate(tex2Dlod(_CurveTex,  float4(hue, 0.25,0,0)).x) - 0.5;
            hue += offset;
            hsv.x = RotateHue(hue, 0.0, 1.0);

            colorLinear = HsvToRgb(hsv);
            colorLinear = Saturation(colorLinear, _HSC.y * satMult);

            return colorLinear;
        }     
        //
        // HDR Grading process
        //
        float3 LogGradeHDR(float3 colorLog)
        {
            // HDR contrast feels a lot more natural when done in log rather than doing it in linear
            colorLog = Contrast(colorLog, ACEScc_MIDGRAY, _HSC.z);
            return colorLog;
        }

        float3 LinearGradeHDR(float3 colorLinear)
        {
            colorLinear = ApplyCommonGradingSteps(colorLinear);
            return colorLinear;
        }

        float3 ColorGradeHDR(float3 colorLutSpace)
        {
            #if TONEMAPPING_ACES
            {
                float3 colorLinear = LUT_SPACE_DECODE(colorLutSpace);
                float3 aces = unity_to_ACES(colorLinear);

                // ACEScc (log) space
                float3 acescc = ACES_to_ACEScc(aces);
                acescc = LogGradeHDR(acescc);
                aces = ACEScc_to_ACES(acescc);

                // ACEScg (linear) space
                float3 acescg = ACES_to_ACEScg(aces);
                acescg = LinearGradeHDR(acescg);

                // Tonemap ODT(RRT(aces))
                aces = ACEScg_to_ACES(acescg);
                colorLinear = AcesTonemap(aces);

                return colorLinear;
            }
            #else
            {
                // colorLutSpace is already in log space
                colorLutSpace = LogGradeHDR(colorLutSpace);

                // Switch back to linear
                float3 colorLinear = LUT_SPACE_DECODE(colorLutSpace);
                colorLinear = LinearGradeHDR(colorLinear);
                colorLinear = max(0.0, colorLinear);

                // Tonemap
                #if TONEMAPPING_FILMIC
                {
                    colorLinear = NeutralTonemap(colorLinear);
                }
                #elif TONEMAPPING_CUSTOM
                {
                    colorLinear = CustomTonemap(
                        colorLinear, _CustomToneCurve.xyz,
                        _ToeSegmentA, _ToeSegmentB.xy,
                        _MidSegmentA, _MidSegmentB.xy,
                        _ShoSegmentA, _ShoSegmentB.xy
                    );
                }
                #endif

                return colorLinear;
            }
            #endif
        }

       	
				
// Vertex manipulation
float2 TransformTriangleVertexToUV(float2 vertex)
{
    float2 uv = (vertex + 1.0) * 0.5;
    return uv;
}

struct AttributesDefault
{
    float3 vertex : POSITION;
};

struct VaryingsDefault
{
    float4 vertex : SV_POSITION;
    float2 texcoord : TEXCOORD0;
    float2 texcoordStereo : TEXCOORD1;
#if STEREO_INSTANCING_ENABLED
    uint stereoTargetEyeIndex : SV_RenderTargetArrayIndex;
#endif
};

#if STEREO_INSTANCING_ENABLED
float _DepthSlice;
#endif

VaryingsDefault VertDefault(AttributesDefault v)
{
    VaryingsDefault o = (VaryingsDefault)0;
    o.vertex = float4(v.vertex.xy, 0.0, 1.0);
    o.texcoord = TransformTriangleVertexToUV(v.vertex.xy);

#if UNITY_UV_STARTS_AT_TOP_HlSL
    o.texcoord = o.texcoord * float2(1.0, -1.0) + float2(0.0, 1.0);
#endif

    o.texcoordStereo = o.texcoord;

    return o;
}

float4 frag_genLut (VaryingsDefault i) : COLOR
{	 	
	float3 colorLutSpace = GetLutStripValue(i.texcoord, _UserLutParams);
	
    float3 graded = ColorGradeHDR(colorLutSpace);
#if LUT2D
	float3 lookup = ApplyLut2D(_UserLutTex, saturate(graded), _LutParams.xyz);
    graded = lerp(graded, lookup, _LutParams.w);
#endif

    return float4(max(graded, 0.0), 1.0);
}




	