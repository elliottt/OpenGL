--------------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.OpenGL.GL.Shaders
-- Copyright   :  (c) Sven Panne 2002-2006
-- License     :  BSD-style (see the file libraries/OpenGL/LICENSE)
-- 
-- Maintainer  :  sven.panne@aedion.de
-- Stability   :  stable
-- Portability :  portable
--
-- This module corresponds to sections 2.15 (Vertex Shaders) and section 3.11
-- (Fragment Shaders) of the OpenGL 2.1 specs.
--
--------------------------------------------------------------------------------

module Graphics.Rendering.OpenGL.GL.Shaders (
   -- * Shader Objects
   Shader, VertexShader, FragmentShader, shaderDeleteStatus, shaderSource,
   compileShader, compileStatus, shaderInfoLog,

   -- * Program Objects
   Program, programDeleteStatus, attachedShaders, linkProgram, linkStatus,
   programInfoLog, validateProgram, validateStatus, currentProgram,

   -- * Vertex attributes
   AttribLocation(..), attribLocation, VariableType(..), activeAttribs,
   Vertex1(..), VertexAttrib, VertexAttribComponent(..),

   -- * Uniform variables
   UniformLocation, uniformLocation, activeUniforms, Uniform(..),
   UniformComponent,

   -- * Implementation limits related to GLSL
   maxVertexTextureImageUnits, maxTextureImageUnits,
   maxCombinedTextureImageUnits, maxTextureCoords, maxVertexUniformComponents,
   maxFragmentUniformComponents, maxVertexAttribs, maxVaryingFloats
) where

import Control.Monad ( replicateM, mapM_, foldM )
import Control.Monad.Fix ( MonadFix(..) )
import Data.Int
import Data.List ( genericLength, (\\) )
import Foreign.C.String ( peekCAStringLen, withCAStringLen )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Array ( allocaArray, withArray, peekArray )
import Foreign.Marshal.Utils ( withMany )
import Foreign.Ptr ( Ptr, castPtr, nullPtr )
import Foreign.Storable ( Storable(peek) )
import Graphics.Rendering.OpenGL.GL.BasicTypes (
   GLboolean, GLbyte, GLubyte, GLchar, GLshort, GLushort, GLint, GLuint,
   GLsizei, GLenum, GLfloat, GLdouble )
import Graphics.Rendering.OpenGL.GL.BufferObjects ( ObjectName(..) )
import Graphics.Rendering.OpenGL.GL.Extensions (
   FunPtr, unsafePerformIO, Invoker, getProcAddress )
import Graphics.Rendering.OpenGL.GL.GLboolean ( unmarshalGLboolean )
import Graphics.Rendering.OpenGL.GL.PeekPoke ( peek1 )
import Graphics.Rendering.OpenGL.GL.QueryUtils (
   GetPName(GetMaxCombinedTextureImageUnits, GetMaxFragmentUniformComponents,
            GetMaxTextureCoords, GetMaxTextureImageUnits,GetMaxVaryingFloats,
            GetMaxVertexAttribs, GetMaxVertexTextureImageUnits,
            GetMaxVertexUniformComponents, GetCurrentProgram),
   getInteger1, getSizei1 )
import Graphics.Rendering.OpenGL.GL.StateVar (
   HasGetter(get), GettableStateVar, makeGettableStateVar, StateVar,
   makeStateVar )
import Graphics.Rendering.OpenGL.GL.VertexSpec (
   Vertex2(..), Vertex3(..), Vertex4(..) )

--------------------------------------------------------------------------------

#include "HsOpenGLExt.h"
#include "HsOpenGLTypes.h"

--------------------------------------------------------------------------------

type GLStringLen = (Ptr GLchar, GLsizei)

peekGLstringLen :: GLStringLen -> IO String
peekGLstringLen (p,l) = peekCAStringLen (castPtr p, fromIntegral l)

withGLStringLen :: String -> (GLStringLen -> IO a) -> IO a
withGLStringLen s act =
   withCAStringLen s $ \(p,len) ->
      act (castPtr p, fromIntegral len)

--------------------------------------------------------------------------------

newtype VertexShader = VertexShader { vertexShaderID :: GLuint }
   deriving ( Eq, Ord, Show )

newtype FragmentShader = FragmentShader { fragmentShaderID :: GLuint }
   deriving ( Eq, Ord, Show )

--------------------------------------------------------------------------------

class Shader s where
   shaderID :: s -> GLuint
   makeShader :: GLuint -> s
   shaderType :: s -> GLenum

instance Shader VertexShader where
   makeShader = VertexShader
   shaderID = vertexShaderID
   shaderType = const 0x8B31

instance Shader FragmentShader where
   makeShader = FragmentShader
   shaderID = fragmentShaderID
   shaderType = const 0x8B30

--------------------------------------------------------------------------------

instance ObjectName VertexShader where
   genObjectNames = genShaderNames
   deleteObjectNames = deleteShaderNames
   isObjectName = isShaderName

instance ObjectName FragmentShader where
   genObjectNames = genShaderNames
   deleteObjectNames = deleteShaderNames
   isObjectName = isShaderName

genShaderNames :: Shader s => Int -> IO [s]
genShaderNames n = replicateM n createShader

createShader :: Shader s => IO s
createShader = mfix (fmap makeShader . glCreateShader . shaderType)

deleteShaderNames :: Shader s => [s] -> IO ()
deleteShaderNames = mapM_ (glDeleteShader . shaderID)

isShaderName :: Shader s => s -> IO Bool
isShaderName = fmap unmarshalGLboolean . glIsShader . shaderID

EXTENSION_ENTRY("OpenGL 2.0",glCreateShader,GLenum -> IO GLuint)
EXTENSION_ENTRY("OpenGL 2.0",glDeleteShader,GLuint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glIsShader,GLuint -> IO GLboolean)

--------------------------------------------------------------------------------

compileShader :: Shader s => s -> IO ()
compileShader = glCompileShader . shaderID

EXTENSION_ENTRY("OpenGL 2.0",glCompileShader,GLuint -> IO ())

--------------------------------------------------------------------------------

shaderSource :: Shader s => s -> StateVar [String]
shaderSource shader =
   makeStateVar (getShaderSource shader) (setShaderSource shader)

setShaderSource :: Shader s => s -> [String] -> IO ()
setShaderSource shader srcs = do
   let len = genericLength srcs
   withMany withGLStringLen srcs $ \charBufsAndLengths -> do
      let (charBufs, lengths) = unzip charBufsAndLengths
      withArray charBufs $ \charBufsBuf ->
         withArray lengths $ \lengthsBuf ->
            glShaderSource (shaderID shader) len charBufsBuf lengthsBuf

EXTENSION_ENTRY("OpenGL 2.0",glShaderSource,GLuint -> GLsizei -> Ptr (Ptr GLchar) -> Ptr GLint -> IO ())

getShaderSource :: Shader s => s -> IO [String]
getShaderSource shader = do
   src <- get (stringQuery (shaderSourceLength shader)
                           (glGetShaderSource (shaderID shader)))
   return [src]

EXTENSION_ENTRY("OpenGL 2.0",glGetShaderSource,GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLchar -> IO ())

stringQuery :: GettableStateVar GLsizei -> (GLsizei -> Ptr GLsizei -> Ptr GLchar -> IO ()) -> GettableStateVar String
stringQuery lengthVar getStr =
   makeGettableStateVar $ do
      len <- get lengthVar
      allocaArray (fromIntegral len) $ \buf -> do
         getStr len nullPtr buf
         peekGLstringLen (buf, len)

--------------------------------------------------------------------------------

shaderInfoLog :: Shader s => s -> GettableStateVar String
shaderInfoLog shader =
   stringQuery (shaderInfoLogLength shader) (glGetShaderInfoLog (shaderID shader))

EXTENSION_ENTRY("OpenGL 2.0",glGetShaderInfoLog,GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLchar -> IO ())

--------------------------------------------------------------------------------

shaderDeleteStatus :: Shader s => s -> GettableStateVar Bool
shaderDeleteStatus = shaderVar unmarshalGLboolean ShaderDeleteStatus

compileStatus :: Shader s => s -> GettableStateVar Bool
compileStatus = shaderVar unmarshalGLboolean CompileStatus

shaderInfoLogLength :: Shader s => s -> GettableStateVar GLsizei
shaderInfoLogLength = shaderVar fromIntegral ShaderInfoLogLength

shaderSourceLength :: Shader s => s -> GettableStateVar GLsizei
shaderSourceLength = shaderVar fromIntegral ShaderSourceLength

shaderTypeEnum :: Shader s => s -> GettableStateVar GLenum
shaderTypeEnum = shaderVar fromIntegral ShaderType

--------------------------------------------------------------------------------

data GetShaderPName =
     ShaderDeleteStatus
   | CompileStatus
   | ShaderInfoLogLength
   | ShaderSourceLength
   | ShaderType

marshalGetShaderPName :: GetShaderPName -> GLenum
marshalGetShaderPName x = case x of
   ShaderDeleteStatus -> 0x8B80
   CompileStatus -> 0x8B81
   ShaderInfoLogLength -> 0x8B84
   ShaderSourceLength -> 0x8B88
   ShaderType -> 0x8B4F

shaderVar :: Shader s => (GLint -> a) -> GetShaderPName -> s -> GettableStateVar a
shaderVar f p shader =
   makeGettableStateVar $
      alloca $ \buf -> do
         glGetShaderiv (shaderID shader) (marshalGetShaderPName p) buf
         peek1 f buf

EXTENSION_ENTRY("OpenGL 2.0",glGetShaderiv,GLuint -> GLenum -> Ptr GLint -> IO ())

--------------------------------------------------------------------------------

newtype Program = Program { programID :: GLuint }
   deriving ( Eq, Ord, Show )

instance ObjectName Program where
   genObjectNames n = replicateM n $ fmap Program glCreateProgram
   deleteObjectNames = mapM_ (glDeleteProgram . programID)
   isObjectName = fmap unmarshalGLboolean . glIsProgram . programID

EXTENSION_ENTRY("OpenGL 2.0",glCreateProgram,IO GLuint)
EXTENSION_ENTRY("OpenGL 2.0",glDeleteProgram,GLuint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glIsProgram,GLuint -> IO GLboolean)

--------------------------------------------------------------------------------

attachedShaders :: Program -> StateVar ([VertexShader],[FragmentShader])
attachedShaders program =
   makeStateVar (getAttachedShaders program) (setAttachedShaders program)

getAttachedShaders :: Program -> IO ([VertexShader],[FragmentShader])
getAttachedShaders program = getAttachedShaderIDs program >>= splitShaderIDs

getAttachedShaderIDs :: Program -> IO [GLuint]
getAttachedShaderIDs program = do
   numShaders <- get (numAttachedShaders program)
   allocaArray (fromIntegral numShaders) $ \buf -> do
      glGetAttachedShaders (programID program) numShaders nullPtr buf
      peekArray (fromIntegral numShaders) buf

EXTENSION_ENTRY("OpenGL 2.0",glGetAttachedShaders,GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLuint -> IO ())

splitShaderIDs :: [GLuint] -> IO ([VertexShader],[FragmentShader])
splitShaderIDs ids = do
   (vs, fs) <- partitionM isVertexShaderID ids
   return (map VertexShader vs, map FragmentShader fs)

isVertexShaderID :: GLuint -> IO Bool
isVertexShaderID x = do
   t <- get (shaderTypeEnum (VertexShader x))
   return $ t == shaderType (undefined :: VertexShader)

partitionM :: (a -> IO Bool) -> [a] -> IO ([a],[a])
partitionM p = foldM select ([],[])
   where select (ts, fs) x = do
            b <- p x
            return $ if b then (x:ts, fs) else (ts, x:fs)

setAttachedShaders :: Program -> ([VertexShader],[FragmentShader]) -> IO ()
setAttachedShaders program (vs, fs) = do
   currentIDs <- getAttachedShaderIDs program
   let newIDs = map shaderID vs ++ map shaderID fs
   mapM_ (glAttachShader program) (newIDs \\ currentIDs)
   mapM_ (glDetachShader program) (currentIDs \\ newIDs)

EXTENSION_ENTRY("OpenGL 2.0",glAttachShader,Program -> GLuint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glDetachShader,Program -> GLuint -> IO ())

--------------------------------------------------------------------------------

linkProgram :: Program -> IO ()
linkProgram = glLinkProgram

EXTENSION_ENTRY("OpenGL 2.0",glLinkProgram,Program -> IO ())

currentProgram :: StateVar (Maybe Program)
currentProgram =
   makeStateVar
      (do p <- getCurrentProgram
          return $ if p == noProgram then Nothing else Just p)
      (glUseProgram . maybe noProgram id)

getCurrentProgram :: IO Program
getCurrentProgram = fmap Program $ getInteger1 fromIntegral GetCurrentProgram

noProgram :: Program
noProgram = Program 0

EXTENSION_ENTRY("OpenGL 2.0",glUseProgram,Program -> IO ())

validateProgram :: Program -> IO ()
validateProgram = glValidateProgram

EXTENSION_ENTRY("OpenGL 2.0",glValidateProgram,Program -> IO ())

programInfoLog :: Program -> GettableStateVar String
programInfoLog p =
   stringQuery (programInfoLogLength p) (glGetProgramInfoLog (programID p))

EXTENSION_ENTRY("OpenGL 2.0",glGetProgramInfoLog,GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLchar -> IO ())

--------------------------------------------------------------------------------

programDeleteStatus :: Program -> GettableStateVar Bool
programDeleteStatus = programVar unmarshalGLboolean ProgramDeleteStatus

linkStatus :: Program -> GettableStateVar Bool
linkStatus = programVar unmarshalGLboolean LinkStatus

validateStatus :: Program -> GettableStateVar Bool
validateStatus = programVar unmarshalGLboolean ValidateStatus

programInfoLogLength :: Program -> GettableStateVar GLsizei
programInfoLogLength = programVar fromIntegral ProgramInfoLogLength

numAttachedShaders :: Program -> GettableStateVar GLsizei
numAttachedShaders = programVar fromIntegral AttachedShaders

activeAttributes :: Program -> GettableStateVar GLuint
activeAttributes = programVar fromIntegral ActiveAttributes

activeAttributeMaxLength :: Program -> GettableStateVar GLsizei
activeAttributeMaxLength = programVar fromIntegral ActiveAttributeMaxLength

numActiveUniforms :: Program -> GettableStateVar GLuint
numActiveUniforms = programVar fromIntegral ActiveUniforms

activeUniformMaxLength :: Program -> GettableStateVar GLsizei
activeUniformMaxLength = programVar fromIntegral ActiveUniformMaxLength

--------------------------------------------------------------------------------

data GetProgramPName =
     ProgramDeleteStatus
   | LinkStatus
   | ValidateStatus
   | ProgramInfoLogLength
   | AttachedShaders
   | ActiveAttributes
   | ActiveAttributeMaxLength
   | ActiveUniforms
   | ActiveUniformMaxLength

marshalGetProgramPName :: GetProgramPName -> GLenum
marshalGetProgramPName x = case x of
   ProgramDeleteStatus -> 0x8B80
   LinkStatus -> 0x8B82
   ValidateStatus -> 0x8B83
   ProgramInfoLogLength -> 0x8B84
   AttachedShaders -> 0x8B85
   ActiveAttributes -> 0x8B89
   ActiveAttributeMaxLength -> 0x8B8A
   ActiveUniforms -> 0x8B86
   ActiveUniformMaxLength -> 0x8B87

programVar :: (GLint -> a) -> GetProgramPName -> Program -> GettableStateVar a
programVar f p program =
   makeGettableStateVar $
      alloca $ \buf -> do
         glGetProgramiv (programID program) (marshalGetProgramPName p) buf
         peek1 f buf

EXTENSION_ENTRY("OpenGL 2.0",glGetProgramiv,GLuint -> GLenum -> Ptr GLint -> IO ())

--------------------------------------------------------------------------------

newtype AttribLocation = AttribLocation GLuint
   deriving ( Eq, Ord, Show )

attribLocation :: Program -> String -> StateVar AttribLocation
attribLocation program name =
   makeStateVar (getAttribLocation program name)
                (\location -> bindAttribLocation program location name)

getAttribLocation :: Program -> String -> IO AttribLocation
getAttribLocation program name =
   withGLStringLen name $ \(buf,_) ->
      fmap (AttribLocation . fromIntegral) $
        glGetAttribLocation program buf

EXTENSION_ENTRY("OpenGL 2.0",glGetAttribLocation,Program -> Ptr GLchar -> IO GLint)

bindAttribLocation :: Program -> AttribLocation -> String -> IO ()
bindAttribLocation program location name =
   withGLStringLen name $ \(buf,_) ->
      glBindAttribLocation program location buf

EXTENSION_ENTRY("OpenGL 2.0",glBindAttribLocation,Program -> AttribLocation -> Ptr GLchar -> IO ())

--------------------------------------------------------------------------------

data VariableType =
     Float'
   | FloatVec2
   | FloatVec3
   | FloatVec4
   | FloatMat2
   | FloatMat3
   | FloatMat4
   | Int'
   | IntVec2
   | IntVec3
   | IntVec4
   | Bool
   | BoolVec2
   | BoolVec3
   | BoolVec4
   | Sampler1D
   | Sampler2D
   | Sampler3D
   | SamplerCube
   | Sampler1DShadow
   | Sampler2DShadow
   deriving ( Eq, Ord, Show )

unmarshalVariableType :: GLenum -> VariableType
unmarshalVariableType x
   | x == 0x1406 = Float'
   | x == 0x8B50 = FloatVec2
   | x == 0x8B51 = FloatVec3
   | x == 0x8B52 = FloatVec4
   | x == 0x8B5A = FloatMat2
   | x == 0x8B5B = FloatMat3
   | x == 0x8B5C = FloatMat4
   | x == 0x1404 = Int'
   | x == 0x8B53 = IntVec2
   | x == 0x8B54 = IntVec3
   | x == 0x8B55 = IntVec4
   | x == 0x8B56 = Bool
   | x == 0x8B57 = BoolVec2
   | x == 0x8B58 = BoolVec3
   | x == 0x8B59 = BoolVec4
   | x == 0x8B5D = Sampler1D
   | x == 0x8B5E = Sampler2D
   | x == 0x8B5F = Sampler3D
   | x == 0x8B60 = SamplerCube
   | x == 0x8B61 = Sampler1DShadow
   | x == 0x8B62 = Sampler2DShadow
   | otherwise = error ("unmarshalVariableType: illegal value " ++ show x)

--------------------------------------------------------------------------------

activeVars :: (Program -> GettableStateVar GLuint)
           -> (Program -> GettableStateVar GLsizei)
           -> (Program -> GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLint -> Ptr GLenum -> Ptr GLchar -> IO ())
           -> Program -> GettableStateVar [(GLint,VariableType,String)]
activeVars numVars maxLength getter program =
   makeGettableStateVar $ do
      numActiveVars <- get (numVars program)
      maxLen <- get (maxLength program)
      allocaArray (fromIntegral maxLen) $ \nameBuf ->
         alloca $ \nameLengthBuf ->
            alloca $ \sizeBuf ->
               alloca $ \typeBuf ->
                  flip mapM [0 .. numActiveVars - 1] $ \i -> do
                    getter program i maxLen nameLengthBuf sizeBuf typeBuf nameBuf
                    l <- peek nameLengthBuf
                    s <- peek sizeBuf
                    t <- peek typeBuf
                    n <- peekGLstringLen (nameBuf, l)
                    return (s, unmarshalVariableType t, n)

activeAttribs :: Program -> GettableStateVar [(GLint,VariableType,String)]
activeAttribs = activeVars activeAttributes activeAttributeMaxLength glGetActiveAttrib

EXTENSION_ENTRY("OpenGL 2.0",glGetActiveAttrib,Program -> GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLint -> Ptr GLenum -> Ptr GLchar -> IO ())

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttribPointer,GLuint -> GLint -> GLenum -> GLboolean -> GLsizei -> Ptr a -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glDisableVertexAttribArray,GLuint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glEnableVertexAttribArray,GLuint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glGetVertexAttribPointerv,GLuint -> GLenum -> Ptr (Ptr a) -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glGetVertexAttribdv,GLuint -> GLenum -> Ptr GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glGetVertexAttribfv,GLuint -> GLenum -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glGetVertexAttribiv,GLuint -> GLenum -> Ptr GLint -> IO ())

--------------------------------------------------------------------------------

class VertexAttribComponent a where
   vertexAttrib1 :: AttribLocation -> a -> IO ()
   vertexAttrib2 :: AttribLocation -> a -> a -> IO ()
   vertexAttrib3 :: AttribLocation -> a -> a -> a -> IO ()
   vertexAttrib4 :: AttribLocation -> a -> a -> a -> a -> IO ()

   vertexAttrib1v :: AttribLocation -> Ptr a -> IO ()
   vertexAttrib2v :: AttribLocation -> Ptr a -> IO ()
   vertexAttrib3v :: AttribLocation -> Ptr a -> IO ()
   vertexAttrib4v :: AttribLocation -> Ptr a -> IO ()

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1s,AttribLocation -> GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2s,AttribLocation -> GLshort -> GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3s,AttribLocation -> GLshort -> GLshort -> GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4s,AttribLocation -> GLshort -> GLshort -> GLshort -> GLshort -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1sv,AttribLocation -> Ptr GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2sv,AttribLocation -> Ptr GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3sv,AttribLocation -> Ptr GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4sv,AttribLocation -> Ptr GLshort -> IO ())

instance VertexAttribComponent GLshort_ where
   vertexAttrib1 = glVertexAttrib1s
   vertexAttrib2 = glVertexAttrib2s
   vertexAttrib3 = glVertexAttrib3s
   vertexAttrib4 = glVertexAttrib4s

   vertexAttrib1v = glVertexAttrib1sv
   vertexAttrib2v = glVertexAttrib2sv
   vertexAttrib3v = glVertexAttrib3sv
   vertexAttrib4v = glVertexAttrib4sv

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1f,AttribLocation -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2f,AttribLocation -> GLfloat -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3f,AttribLocation -> GLfloat -> GLfloat -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4f,AttribLocation -> GLfloat -> GLfloat -> GLfloat -> GLfloat -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1fv,AttribLocation -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2fv,AttribLocation -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3fv,AttribLocation -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4fv,AttribLocation -> Ptr GLfloat -> IO ())

instance VertexAttribComponent GLfloat_ where
   vertexAttrib1 = glVertexAttrib1f
   vertexAttrib2 = glVertexAttrib2f
   vertexAttrib3 = glVertexAttrib3f
   vertexAttrib4 = glVertexAttrib4f

   vertexAttrib1v = glVertexAttrib1fv
   vertexAttrib2v = glVertexAttrib2fv
   vertexAttrib3v = glVertexAttrib3fv
   vertexAttrib4v = glVertexAttrib4fv

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1d,AttribLocation -> GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2d,AttribLocation -> GLdouble -> GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3d,AttribLocation -> GLdouble -> GLdouble -> GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4d,AttribLocation -> GLdouble -> GLdouble -> GLdouble -> GLdouble -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib1dv,AttribLocation -> Ptr GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib2dv,AttribLocation -> Ptr GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib3dv,AttribLocation -> Ptr GLdouble -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4dv,AttribLocation -> Ptr GLdouble -> IO ())

instance VertexAttribComponent GLdouble_ where
   vertexAttrib1 = glVertexAttrib1d
   vertexAttrib2 = glVertexAttrib2d
   vertexAttrib3 = glVertexAttrib3d
   vertexAttrib4 = glVertexAttrib4d

   vertexAttrib1v = glVertexAttrib1dv
   vertexAttrib2v = glVertexAttrib2dv
   vertexAttrib3v = glVertexAttrib3dv
   vertexAttrib4v = glVertexAttrib4dv

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4bv,AttribLocation -> Ptr GLbyte -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4ubv,AttribLocation -> Ptr GLubyte -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4usv,AttribLocation -> Ptr GLushort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4iv,AttribLocation -> Ptr GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4uiv,AttribLocation -> Ptr GLuint -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nbv,AttribLocation -> Ptr GLbyte -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nubv,AttribLocation -> Ptr GLubyte -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nusv,AttribLocation -> Ptr GLushort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Niv,AttribLocation -> Ptr GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nuiv,AttribLocation -> Ptr GLuint -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nsv,AttribLocation -> Ptr GLshort -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glVertexAttrib4Nub,AttribLocation -> GLubyte -> GLubyte -> GLubyte -> GLubyte -> IO ())

--------------------------------------------------------------------------------

class VertexAttrib a where
   vertexAttrib  :: AttribLocation ->     a -> IO ()
   vertexAttribv :: AttribLocation -> Ptr a -> IO ()

newtype Vertex1 a = Vertex1 a
   deriving ( Eq, Ord, Show )

instance VertexAttribComponent a => VertexAttrib (Vertex1 a) where
   vertexAttrib location (Vertex1 x) = vertexAttrib1 location x
   vertexAttribv location = vertexAttrib1v location . (castPtr :: Ptr (Vertex1 b) -> Ptr b)

instance VertexAttribComponent a => VertexAttrib (Vertex2 a) where
   vertexAttrib location (Vertex2 x y) = vertexAttrib2 location x y
   vertexAttribv location = vertexAttrib2v location . (castPtr :: Ptr (Vertex2 b) -> Ptr b)

instance VertexAttribComponent a => VertexAttrib (Vertex3 a) where
   vertexAttrib location (Vertex3 x y z) = vertexAttrib3 location x y z
   vertexAttribv location = vertexAttrib3v location . (castPtr :: Ptr (Vertex3 b) -> Ptr b)

instance VertexAttribComponent a => VertexAttrib (Vertex4 a) where
   vertexAttrib location (Vertex4 x y z w) = vertexAttrib4 location x y z w
   vertexAttribv location = vertexAttrib4v location . (castPtr :: Ptr (Vertex4 b) -> Ptr b)

--------------------------------------------------------------------------------

newtype UniformLocation = UniformLocation GLint
   deriving ( Eq, Ord, Show )

uniformLocation :: Program -> String -> GettableStateVar UniformLocation
uniformLocation program name =
   makeGettableStateVar $
      withGLStringLen name $ \(buf,_) ->
         fmap UniformLocation $
            glGetUniformLocation program buf

EXTENSION_ENTRY("OpenGL 2.0",glGetUniformLocation,Program -> Ptr GLchar -> IO GLint)

--------------------------------------------------------------------------------

activeUniforms :: Program -> GettableStateVar [(GLint,VariableType,String)]
activeUniforms = activeVars numActiveUniforms activeUniformMaxLength glGetActiveUniform

EXTENSION_ENTRY("OpenGL 2.0",glGetActiveUniform,Program -> GLuint -> GLsizei -> Ptr GLsizei -> Ptr GLint -> Ptr GLenum -> Ptr GLchar -> IO ())

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glGetUniformfv,GLuint -> GLint -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glGetUniformiv,GLuint -> GLint -> Ptr GLint -> IO ())

--------------------------------------------------------------------------------

class UniformComponent a where
   uniform1 :: UniformLocation -> a -> IO ()
   uniform2 :: UniformLocation -> a -> a -> IO ()
   uniform3 :: UniformLocation -> a -> a -> a -> IO ()
   uniform4 :: UniformLocation -> a -> a -> a -> a -> IO ()

   uniform1v :: UniformLocation -> GLsizei -> Ptr a -> IO ()
   uniform2v :: UniformLocation -> GLsizei -> Ptr a -> IO ()
   uniform3v :: UniformLocation -> GLsizei -> Ptr a -> IO ()
   uniform4v :: UniformLocation -> GLsizei -> Ptr a -> IO ()

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glUniform1i,UniformLocation -> GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform2i,UniformLocation -> GLint -> GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform3i,UniformLocation -> GLint -> GLint -> GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform4i,UniformLocation -> GLint -> GLint -> GLint -> GLint -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glUniform1iv,UniformLocation -> GLsizei -> Ptr GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform2iv,UniformLocation -> GLsizei -> Ptr GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform3iv,UniformLocation -> GLsizei -> Ptr GLint -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform4iv,UniformLocation -> GLsizei -> Ptr GLint -> IO ())

instance UniformComponent GLint_ where
   uniform1 = glUniform1i
   uniform2 = glUniform2i
   uniform3 = glUniform3i
   uniform4 = glUniform4i

   uniform1v = glUniform1iv
   uniform2v = glUniform2iv
   uniform3v = glUniform3iv
   uniform4v = glUniform4iv

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glUniform1f,UniformLocation -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform2f,UniformLocation -> GLfloat -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform3f,UniformLocation -> GLfloat -> GLfloat -> GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform4f,UniformLocation -> GLfloat -> GLfloat -> GLfloat -> GLfloat -> IO ())

EXTENSION_ENTRY("OpenGL 2.0",glUniform1fv,UniformLocation -> GLsizei -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform2fv,UniformLocation -> GLsizei -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform3fv,UniformLocation -> GLsizei -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniform4fv,UniformLocation -> GLsizei -> Ptr GLfloat -> IO ())

instance UniformComponent GLfloat_ where
   uniform1 = glUniform1f
   uniform2 = glUniform2f
   uniform3 = glUniform3f
   uniform4 = glUniform4f

   uniform1v = glUniform1fv
   uniform2v = glUniform2fv
   uniform3v = glUniform3fv
   uniform4v = glUniform4fv

--------------------------------------------------------------------------------

EXTENSION_ENTRY("OpenGL 2.0",glUniformMatrix2fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniformMatrix3fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.0",glUniformMatrix4fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix2x3fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix3x2fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix2x4fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix4x2fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix3x4fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())
EXTENSION_ENTRY("OpenGL 2.1",glUniformMatrix4x3fv,UniformLocation -> GLsizei -> GLboolean -> Ptr GLfloat -> IO ())

--------------------------------------------------------------------------------

class Uniform a where
   uniform  :: UniformLocation ->                a -> IO ()
   uniformv :: UniformLocation -> GLsizei -> Ptr a -> IO ()

instance UniformComponent a => Uniform (Vertex1 a) where
   uniform location (Vertex1 x) = uniform1 location x
   uniformv location count = uniform1v location count . (castPtr :: Ptr (Vertex1 b) -> Ptr b)

instance UniformComponent a => Uniform (Vertex2 a) where
   uniform location (Vertex2 x y) = uniform2 location x y
   uniformv location count = uniform2v location count . (castPtr :: Ptr (Vertex2 b) -> Ptr b)

instance UniformComponent a => Uniform (Vertex3 a) where
   uniform location (Vertex3 x y z) = uniform3 location x y z
   uniformv location count = uniform3v location count . (castPtr :: Ptr (Vertex3 b) -> Ptr b)

instance UniformComponent a => Uniform (Vertex4 a) where
   uniform location (Vertex4 x y z w) = uniform4 location x y z w
   uniformv location count = uniform4v location count . (castPtr :: Ptr (Vertex4 b) -> Ptr b)

--------------------------------------------------------------------------------

-- | Contains the number of hardware units that can be used to access texture
-- maps from the vertex processor. The minimum legal value is 0.

maxVertexTextureImageUnits :: GettableStateVar GLint
maxVertexTextureImageUnits = getLimit GetMaxVertexTextureImageUnits

-- | Contains the total number of hardware units that can be used to access
-- texture maps from the fragment processor. The minimum legal value is 2.

maxTextureImageUnits :: GettableStateVar GLint
maxTextureImageUnits = getLimit GetMaxTextureImageUnits

-- | Contains the total number of hardware units that can be used to access
-- texture maps from the vertex processor and the fragment processor combined.
-- Note: If the vertex shader and the fragment processing stage access the same
-- texture image unit, then that counts as using two texture image units. The
-- minimum legal value is 2.

maxCombinedTextureImageUnits :: GettableStateVar GLint
maxCombinedTextureImageUnits = getLimit GetMaxCombinedTextureImageUnits

-- | Contains the number of texture coordinate sets that are available. The
-- minimum legal value is 2.

maxTextureCoords :: GettableStateVar GLint
maxTextureCoords = getLimit GetMaxTextureCoords

-- | Contains the number of individual components (i.e., floating-point, integer
-- or boolean values) that are available for vertex shader uniform variables.
-- The minimum legal value is 512.
maxVertexUniformComponents :: GettableStateVar GLint
maxVertexUniformComponents = getLimit GetMaxVertexUniformComponents

-- | Contains the number of individual components (i.e., floating-point, integer
-- or boolean values) that are available for fragment shader uniform variables.
-- The minimum legal value is 64.

maxFragmentUniformComponents :: GettableStateVar GLint
maxFragmentUniformComponents = getLimit GetMaxFragmentUniformComponents

-- | Contains the number of active vertex attributes that are available. The
-- minimum legal value is 16.

maxVertexAttribs :: GettableStateVar GLint
maxVertexAttribs = getLimit GetMaxVertexAttribs

-- | Contains the number of individual floating-point values available for
-- varying variables. The minimum legal value is 32.

maxVaryingFloats :: GettableStateVar GLint
maxVaryingFloats = getLimit GetMaxVaryingFloats

getLimit :: GetPName -> GettableStateVar GLsizei
getLimit = makeGettableStateVar . getSizei1 id