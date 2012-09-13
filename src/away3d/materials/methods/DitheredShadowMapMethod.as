package away3d.materials.methods
{
	import away3d.arcane;
	import away3d.core.managers.Stage3DProxy;
	import away3d.lights.DirectionalLight;
	import away3d.materials.methods.MethodVO;
	import away3d.materials.compilation.ShaderRegisterCache;
	import away3d.materials.compilation.ShaderRegisterElement;
	import away3d.textures.BitmapTexture;

	import flash.display.BitmapData;

	use namespace arcane;

	public class DitheredShadowMapMethod extends ShadowMapMethodBase
	{
		private static var _grainTexture : BitmapTexture;
		private static var _grainUsages : int;
		private static var _grainBitmapData : BitmapData;
		private var _depthMapSize : int;
		private var _range : Number = 1;
		private var _numSamples : int;

		/**
		 * Creates a new DitheredShadowMapMethod object.
		 * @param castingLight The light casting the shadows
		 * @param numSamples The amount of samples to take for dithering. Minimum 1, maximum 8.
		 */
		public function DitheredShadowMapMethod(castingLight : DirectionalLight, numSamples : int = 4)
		{
			// todo: implement for point lights
			super(castingLight);

			// area to sample in texture space
			_depthMapSize = castingLight.shadowMapper.depthMapSize;

			this.numSamples = numSamples;

			++_grainUsages;

			if (!_grainTexture)
				initGrainTexture();
		}

		public function get numSamples() : int
		{
			return _numSamples;
		}

		public function set numSamples(value : int) : void
		{
			_numSamples = value;
			if (_numSamples < 1) _numSamples = 1;
			else if (_numSamples > 8) _numSamples = 8;
			invalidateShaderProgram();
		}

		override arcane function initVO(vo : MethodVO) : void
		{
			super.initVO(vo);
			vo.needsProjection = true;
		}

		override arcane function initConstants(vo : MethodVO) : void
		{
			super.initConstants(vo);

			var fragmentData : Vector.<Number> = vo.fragmentData;
			var index : int = vo.fragmentConstantsIndex;
			fragmentData[index + 8] = 1/_numSamples;

		}

		public function get range() : Number
		{
			return _range*2;
		}

		public function set range(value : Number) : void
		{
			_range = value/2;
		}

		private function initGrainTexture() : void
		{
			_grainBitmapData = new BitmapData(64, 64, false);
			var vec : Vector.<uint> = new Vector.<uint>();
			var len : uint = 4096;
			var step : Number = 1/(_depthMapSize*_range);
			var r : Number,  g : Number;

			for (var i : uint = 0; i < len; ++i) {
				r = 2*(Math.random() - .5);
				g = 2*(Math.random() - .5);
				if (r < 0) r -= step;
				else r += step;
				if (g < 0) g -= step;
				else g += step;
				if (r > 1) r = 1;
				else if (r < -1) r = -1;
				if (g > 1) g = 1;
				else if (g < -1) g = -1;
				vec[i] = (int((r*.5 + .5)*0xff) << 16) | (int((g*.5 + .5)*0xff) << 8);
			}

			_grainBitmapData.setVector(_grainBitmapData.rect, vec);
			_grainTexture = new BitmapTexture(_grainBitmapData);
		}

		override public function dispose() : void
		{
			if (--_grainUsages == 0) {
				_grainTexture.dispose();
				_grainBitmapData.dispose();
				_grainTexture = null;
			}
		}

		arcane override function activate(vo : MethodVO, stage3DProxy : Stage3DProxy) : void
		{
			super.activate(vo,  stage3DProxy);
			vo.fragmentData[vo.fragmentConstantsIndex + 9] = (stage3DProxy.width-1)/63;
			vo.fragmentData[vo.fragmentConstantsIndex + 10] = (stage3DProxy.height-1)/63;
			vo.fragmentData[vo.fragmentConstantsIndex + 11] = 2*_range/_depthMapSize;
			stage3DProxy.setTextureAt(vo.texturesIndex+1, _grainTexture.getTextureForStage3D(stage3DProxy));
		}

		/**
		 * @inheritDoc
		 */
		override protected function getPlanarFragmentCode(vo : MethodVO, regCache : ShaderRegisterCache, targetReg : ShaderRegisterElement) : String
		{
			var depthMapRegister : ShaderRegisterElement = regCache.getFreeTextureReg();
			var grainRegister : ShaderRegisterElement = regCache.getFreeTextureReg();
			var decReg : ShaderRegisterElement = regCache.getFreeFragmentConstant();
			var dataReg : ShaderRegisterElement = regCache.getFreeFragmentConstant();
			var customDataReg : ShaderRegisterElement = regCache.getFreeFragmentConstant();
			var depthCol : ShaderRegisterElement = regCache.getFreeFragmentVectorTemp();
			var uvReg : ShaderRegisterElement;
			var code : String = "";

			vo.fragmentConstantsIndex = decReg.index*4;

			regCache.addFragmentTempUsages(depthCol, 1);

			uvReg = regCache.getFreeFragmentVectorTemp();

			code += "div " + uvReg + ", " + _projectionReg + ", " + _projectionReg + ".w\n" +
					"mul " + uvReg + ".xy, " + uvReg + ".xy, " + customDataReg + ".yz\n" +
					"tex " + uvReg + ", " + uvReg + ", " + grainRegister + " <2d,nearest,repeat,mipnone>\n" +
					"add " + _viewDirFragmentReg+".w, " + _depthMapCoordReg+".z, " + dataReg+".x\n" +     // offset by epsilon

				// keep grain in uvReg.zw
					"sub " + uvReg + ".zw, " + uvReg + ".xy, fc0.xx\n" + 	// uv-.5
					"mul " + uvReg + ".zw, " + uvReg + ".zw, " + customDataReg + ".w\n" +	// (tex unpack scale and tex scale in one)


			// first sample
					"add " + uvReg+".xy, " + uvReg+".zw, " + _depthMapCoordReg+".xy\n" +
					"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
					"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
					"slt " + targetReg+".w, " + _viewDirFragmentReg+".w, " + depthCol+".z\n";    // 0 if in shadow

			if (_numSamples > 4)
				code += "add " + uvReg+".xy, " + uvReg+".xy, " + uvReg+".zw\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			if (_numSamples > 1)
				code +=	"sub " + uvReg+".xy, " + _depthMapCoordReg +".xy, " + uvReg+".zw\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			if (_numSamples > 5)
				code += "sub " + uvReg+".xy, " + uvReg+".xy, " + uvReg+".zw\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			if (_numSamples > 2) {
				code += "neg " + uvReg + ".w, " + uvReg + ".w\n";	// will be rotated 90 degrees when being accessed as wz

				code +=	"add " + uvReg+".xy, " + uvReg+".wz, " + _depthMapCoordReg+".xy\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";
			}

			if (_numSamples > 6)
				code += "add " + uvReg+".xy, " + uvReg+".xy, " + uvReg+".wz\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			if (_numSamples > 3)
				code +=	"sub " + uvReg+".xy, " + _depthMapCoordReg +".xy, " + uvReg+".wz\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			if (_numSamples > 7)
				code += "sub " + uvReg+".xy, " + uvReg+".xy, " + uvReg+".wz\n" +
						"tex " + depthCol + ", " + uvReg + ", " + depthMapRegister + " <2d,nearest,clamp,mipnone>\n" +
						"dp4 " + depthCol+".z, " + depthCol + ", " + decReg + "\n" +
						"slt " + depthCol+".z, " + _viewDirFragmentReg+".w, " + depthCol+".z\n" +    // 0 if in shadow
						"add " + targetReg+".w, " + targetReg+".w, " + depthCol+".z\n";

			regCache.removeFragmentTempUsage(depthCol);

			code += "mul " + targetReg+".w, " + targetReg+".w, " + customDataReg+".x\n";  // average

			vo.texturesIndex = depthMapRegister.index;

			return code;
		}
	}
}