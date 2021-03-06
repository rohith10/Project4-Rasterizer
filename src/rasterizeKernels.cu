// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <ctime>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/device_ptr.h>
#include "rasterizeKernels.h"
#include "rasterizeTools.h"

#if CUDA_VERSION >= 5000
    #include <helper_math.h>
#else
    #include <cutil_math.h>
#endif

glm::vec3* framebuffer;
fragment* depthbuffer;
float* device_vbo;
float* device_nbo;
float* device_cbo;
int* device_ibo;
triangle* primitives;

extern bool outline;

void checkCUDAError(const char *msg) {
  cudaError_t err = cudaGetLastError();
  if( cudaSuccess != err) {
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
	std::cin.get ();
    exit(EXIT_FAILURE); 
  }
} 

//Handy dandy little hashing function that provides seeds for random number generation
__host__ __device__ unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

//Writes a given fragment to a fragment buffer at a given location
__host__ __device__ void writeToDepthbuffer(int x, int y, fragment frag, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    depthbuffer[index] = frag;
  }
}

//Reads a fragment from a given location in a fragment buffer
__host__ __device__ fragment getFromDepthbuffer(int x, int y, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return depthbuffer[index];
  }else{
    fragment f;
    return f;
  }
}

//Writes a given pixel to a pixel buffer at a given location
__host__ __device__ void writeToFramebuffer(int x, int y, glm::vec3 value, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    framebuffer[index] = value;
  }
}

//Reads a pixel from a pixel buffer at a given location
__host__ __device__ glm::vec3 getFromFramebuffer(int x, int y, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return framebuffer[index];
  }else{
    return glm::vec3(0,0,0);
  }
}

// Predicate for remove_if used in back face culling:
struct shouldCullThisObject
{
	__host__ __device__ bool operator () (const triangle aTriangle)
	{
		return (calculateSignedArea (aTriangle) < 0.001f);
	}
};

//Kernel that clears a given pixel buffer with a given color
__global__ void clearImage(glm::vec2 resolution, glm::vec3* image, glm::vec3 color){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      image[index] = color;
    }
}

//Kernel that clears a given fragment buffer with a given fragment
__global__ void clearDepthBuffer(glm::vec2 resolution, fragment* buffer, fragment frag){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      fragment f = frag;
      f.position.x = x;
      f.position.y = y;
	  f.position.z = 1e6;
      buffer[index] = f;
    }
}

//Kernel that writes the image to the OpenGL PBO directly. 
__global__ void sendImageToPBO(uchar4* PBOpos, glm::vec2 resolution, glm::vec3* image){
  
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  
  if(x<=resolution.x && y<=resolution.y){

      glm::vec3 color;      
      color.x = image[index].x*255.0;
      color.y = image[index].y*255.0;
      color.z = image[index].z*255.0;

      if(color.x>255){
        color.x = 255;
      }

      if(color.y>255){
        color.y = 255;
      }

      if(color.z>255){
        color.z = 255;
      }
      
      // Each thread writes one pixel location in the texture (textel)
      PBOpos[index].w = 0;
      PBOpos[index].x = color.x;     
      PBOpos[index].y = color.y;
      PBOpos[index].z = color.z;
  }
}

//TODO: Implement a vertex shader
__global__ void vertexShadeKernel(float* vbo, float *vbo2, int vbosize, float *nbo, int nbosize, cbuffer *constantBuffer)
{
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  __shared__ glm::mat4	ViewProjection;
  __shared__ int	step;
  __shared__ int	normStep;
  __shared__ cbuffer	constBuff;

  if ((threadIdx.x == 0) && (threadIdx.y == 0))
  {
	  constBuff = *constantBuffer;
	  step = vbosize/4;
	  normStep = nbosize / 4;

	  ViewProjection = /*constBuff.projection **/ constBuff.view;
  }

  __syncthreads ();

  if(index<step)
  {
	  glm::vec4 currentVertex (vbo [index], vbo [index+step], vbo [index+(2*step)], vbo [index+(3*step)]);
	  cudaMat4 stupidMat;

	  // Transform to world space for light vector calculation.
	  stupidMat = mat4GLMtoCUDA (constBuff.model);
	  currentVertex = multiplyMV (stupidMat, currentVertex);
 	  vbo2 [index] = constBuff.lightPos [0] - currentVertex.x;	vbo2 [index+step] = constBuff.lightPos [1] - currentVertex.y;	vbo2 [index+(2*step)] = constBuff.lightPos [2] - currentVertex.z;	vbo2 [index+(3*step)] = 0;

	  // Transform vertex to clip space.
	  stupidMat = mat4GLMtoCUDA (ViewProjection);
	  currentVertex = multiplyMV (stupidMat, currentVertex);
	  vbo [index] = currentVertex.x;	vbo [index+step] = currentVertex.y;	vbo [index+(2*step)] = currentVertex.z;	vbo [index+(3*step)] = currentVertex.w;
  }

  if (index < normStep)
  {
	  glm::vec4 currentNormal (nbo [index], nbo [index+normStep], nbo [index+(2*normStep)], nbo [index+(3*normStep)]);
	  cudaMat4 stupidMat;

	  // Transform normal to world space.
	  stupidMat = mat4GLMtoCUDA (constBuff.modelIT);
	  currentNormal = glm::normalize (multiplyMV (stupidMat, currentNormal));

	  nbo [index] = currentNormal.x;	nbo [index+normStep] = currentNormal.y;	nbo [index+(2*normStep)] = currentNormal.z;	nbo [index+(3*normStep)] = currentNormal.w;
  }
}

//TODO: Implement primitive assembly
__global__ void primitiveAssemblyKernel(float* vbo, float* vbo2, int vbosize, float* cbo, int cbosize, int* ibo, int ibosize, 
										float* nbo, int nbosize, triangle* primitives)
{
  __shared__ int colourStep;
  __shared__ int indexStep;		// = primitivesCount.
  __shared__ int vertStep;
  __shared__ int normStep;
  
  if ((threadIdx.x == 0) && (threadIdx.y == 0))
  {
	  colourStep = cbosize / 3;
	  vertStep = vbosize/4;
	  indexStep = ibosize / 3;
	  normStep = nbosize / 4;
  }

  __syncthreads ();

  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
//  int primitivesCount = ibosize/3;

  if(index < indexStep)
  {
	  triangle thisTriangle;
	  
	  int curIndex = ibo [index];
	  thisTriangle.c0.x = cbo [0];	thisTriangle.c0.y = cbo [1];	thisTriangle.c0.z = cbo [2];
	  thisTriangle.p0.x = vbo [curIndex];	thisTriangle.p0.y = vbo [curIndex + vertStep];		thisTriangle.p0.z = vbo [curIndex + (2*vertStep)];		thisTriangle.p0.w = vbo [curIndex + (3*vertStep)];
	  thisTriangle.p0_w.x = vbo2 [curIndex];	thisTriangle.p0_w.y = vbo2 [curIndex + vertStep];		thisTriangle.p0_w.z = vbo2 [curIndex + (2*vertStep)];		thisTriangle.p0_w.w = vbo2 [curIndex + (3*vertStep)];
	  thisTriangle.n0.x = nbo [curIndex];	thisTriangle.n0.y = nbo [curIndex + normStep];		thisTriangle.n0.z = nbo [curIndex + (2*normStep)];		thisTriangle.n0.w = nbo [curIndex + (3*normStep)];

	  curIndex = ibo [index+indexStep];
	  thisTriangle.c1.x = cbo [3];	thisTriangle.c1.y = cbo [4];	thisTriangle.c1.z = cbo [5];
	  thisTriangle.p1.x = vbo [curIndex];	thisTriangle.p1.y = vbo [curIndex + vertStep];		thisTriangle.p1.z = vbo [curIndex + (2*vertStep)];		thisTriangle.p1.w = vbo [curIndex + (3*vertStep)];
	  thisTriangle.p1_w.x = vbo2 [curIndex];	thisTriangle.p1_w.y = vbo2 [curIndex + vertStep];		thisTriangle.p1_w.z = vbo2 [curIndex + (2*vertStep)];		thisTriangle.p1_w.w = vbo2 [curIndex + (3*vertStep)];
	  thisTriangle.n1.x = nbo [curIndex];	thisTriangle.n1.y = nbo [curIndex + normStep];		thisTriangle.n1.z = nbo [curIndex + (2*normStep)];		thisTriangle.n1.w = nbo [curIndex + (3*normStep)];

	  curIndex = ibo [index+(2*indexStep)];
	  thisTriangle.c2.x = cbo [6];	thisTriangle.c2.y = cbo [7];	thisTriangle.c2.z = cbo [8];
	  thisTriangle.p2.x = vbo [curIndex];	thisTriangle.p2.y = vbo [curIndex + vertStep];		thisTriangle.p2.z =	vbo [curIndex + (2*vertStep)];		thisTriangle.p2.w = vbo [curIndex + (3*vertStep)];
	  thisTriangle.p2_w.x = vbo2 [curIndex];	thisTriangle.p2_w.y = vbo2 [curIndex + vertStep];		thisTriangle.p2_w.z =	vbo2 [curIndex + (2*vertStep)];		thisTriangle.p2_w.w = vbo2 [curIndex + (3*vertStep)];
	  thisTriangle.n2.x = nbo [curIndex];	thisTriangle.n2.y = nbo [curIndex + normStep];		thisTriangle.n2.z =	nbo [curIndex + (2*normStep)];		thisTriangle.n2.w = nbo [curIndex + (3*normStep)];
	  
	  primitives [index] = thisTriangle;
  }
}

// Converts all triangles to screen space.
__global__ void convertToScreenSpace(triangle* primitives, int primitivesCount, glm::vec2 resolution)
{
  extern __shared__ triangle primitiveShared [];
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;

  if(index<primitivesCount)
  {
	  primitiveShared [threadIdx.x] = primitives [index];

	  // Convert clip space coordinates to NDC (a.k.a. Perspective divide).
	  if (abs (primitiveShared [threadIdx.x].p0.w) > 0.001)
	  {
		  primitiveShared [threadIdx.x].p0.x /= primitiveShared [threadIdx.x].p0.w;
		  primitiveShared [threadIdx.x].p0.y /= primitiveShared [threadIdx.x].p0.w;
		  primitiveShared [threadIdx.x].p0.z /= primitiveShared [threadIdx.x].p0.w;
	  }

	  if (abs (primitiveShared [threadIdx.x].p1.w) > 0.001)
	  {
		  primitiveShared [threadIdx.x].p1.x /= primitiveShared [threadIdx.x].p1.w;
		  primitiveShared [threadIdx.x].p1.y /= primitiveShared [threadIdx.x].p1.w;
		  primitiveShared [threadIdx.x].p1.z /= primitiveShared [threadIdx.x].p1.w;
	  }

	  if (abs (primitiveShared [threadIdx.x].p2.w) > 0.001)
	  {
		  primitiveShared [threadIdx.x].p2.x /= primitiveShared [threadIdx.x].p2.w;
		  primitiveShared [threadIdx.x].p2.y /= primitiveShared [threadIdx.x].p2.w;
		  primitiveShared [threadIdx.x].p2.z /= primitiveShared [threadIdx.x].p2.w;
	  }

	  // Rescale NDC to be in the range 0.0 to 1.0.
	  primitiveShared [threadIdx.x].p0.x += 1.0f;
	  primitiveShared [threadIdx.x].p0.x /= 2.0f;
	  primitiveShared [threadIdx.x].p0.y += 1.0f;
	  primitiveShared [threadIdx.x].p0.y /= 2.0f;
	  primitiveShared [threadIdx.x].p0.z += 1.0f;
	  primitiveShared [threadIdx.x].p0.z /= 2.0f;

	  primitiveShared [threadIdx.x].p1.x += 1.0f;
	  primitiveShared [threadIdx.x].p1.x /= 2.0f;
	  primitiveShared [threadIdx.x].p1.y += 1.0f;
	  primitiveShared [threadIdx.x].p1.y /= 2.0f;
	  primitiveShared [threadIdx.x].p1.z += 1.0f;
	  primitiveShared [threadIdx.x].p1.z /= 2.0f;

	  primitiveShared [threadIdx.x].p2.x += 1.0f;
	  primitiveShared [threadIdx.x].p2.x /= 2.0f;
	  primitiveShared [threadIdx.x].p2.y += 1.0f;
	  primitiveShared [threadIdx.x].p2.y /= 2.0f;
	  primitiveShared [threadIdx.x].p2.z += 1.0f;
	  primitiveShared [threadIdx.x].p2.z /= 2.0f;

	  // Now multiply with resolution to get screen co-ordinates.
	  primitiveShared [threadIdx.x].p0.x *= resolution.x;
	  primitiveShared [threadIdx.x].p0.y *= resolution.y;
	  
	  primitiveShared [threadIdx.x].p1.x *= resolution.x;
	  primitiveShared [threadIdx.x].p1.y *= resolution.y;
	  
	  primitiveShared [threadIdx.x].p2.x *= resolution.x;
	  primitiveShared [threadIdx.x].p2.y *= resolution.y;

	  primitives [index] = primitiveShared [threadIdx.x];
  }
}

// Mark primitives that are back facing.
__global__ void	markBackFaces (triangle* primitive, int * backFaceMarkerArray, int primitivesCount)
{
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index<primitivesCount)
  {
	  triangle currentPrim = primitive [index];
	  if (calculateSignedArea (currentPrim) > 0)
		  backFaceMarkerArray [index] = 1;
	  else
		  backFaceMarkerArray [index] = 0;
  }
}

// Kernel to do stream compaction.
__global__ void	compactStream (triangle *primitives, triangle *tempPrims, int *shouldCull, int *moveToIndex, int nPrims)
{
	unsigned long	curIndex = blockDim.x*blockIdx.x + threadIdx.x;
	if (curIndex < nPrims)
	{
		int secondArrayIndex = moveToIndex [curIndex];
		if (shouldCull [curIndex])
			tempPrims [secondArrayIndex] = primitives [curIndex];
	}
}

// Rast kernel for primitive parallelized rasterization.
__global__ void rasterizationKernelAlt (triangle* primitive, int nPrimitives, fragment* depthbuffer, glm::vec2 resolution, bool outline)
{
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < nPrimitives)
  {
	    triangle currentPrim = primitive [index];
		glm::vec2  bBoxMin;
		glm::vec2  bBoxMax;

		bBoxMin.x = min (currentPrim.p0.x, min (currentPrim.p1.x, currentPrim.p2.x));
		bBoxMax.x = max (currentPrim.p0.x, max (currentPrim.p1.x, currentPrim.p2.x));

  		bBoxMin.y = min (currentPrim.p0.y, min (currentPrim.p1.y, currentPrim.p2.y));
		bBoxMax.y = max (currentPrim.p0.y, max (currentPrim.p1.y, currentPrim.p2.y));

		for (int j = bBoxMin.y; j < bBoxMax.y; j ++)
			for (int i = bBoxMin.x; i < bBoxMax.x; i ++)
			{
				// First check if the pixel is within window:
				if ((i >= 0) && (i < resolution.x))
					if ((j >= 0) && (j < resolution.y))
					{
						fragment	curFragment;
						glm::vec3	baryCoord;
						bool		pointFound = false;
						
						// Check for subpixel inside tri.
						//baryCoord = calculateBarycentricCoordinate (currentPrim, glm::vec2 (i,j));
						for (float a = -0.5f; a < 1.0f; a += 0.5f)
							for (float b = -0.5f; b < 1.0f; b += 0.5f)
							{
								baryCoord = calculateBarycentricCoordinate (currentPrim, glm::vec2 (i+a,j+b));
								if (isBarycentricCoordInBounds (baryCoord))
								{
									pointFound = true;
									break;
								}
							}

						// If yes, calculate attributes at this point.
						if (/*isBarycentricCoordInBounds (baryCoord)*/pointFound)
						{  
							// We can interpolate the normals using barycentric coordinates because
							// they are in world space and have not gone through the perspective warping.
							curFragment.normal.x =	baryCoord.x * currentPrim.n0.x + 
												baryCoord.y * currentPrim.n1.x + 
												baryCoord.z * currentPrim.n2.x;
					  
							curFragment.normal.y =	baryCoord.x * currentPrim.n0.y + 
												baryCoord.y * currentPrim.n1.y + 
												baryCoord.z * currentPrim.n2.y;

							curFragment.normal.z =	baryCoord.x * (currentPrim.n0.z) + 
												baryCoord.y * (currentPrim.n1.z) + 
												baryCoord.z * (currentPrim.n2.z);

							curFragment.normal = glm::normalize (curFragment.normal);

							curFragment.lightVec.x =	baryCoord.x * currentPrim.p0_w.x + 
												baryCoord.y * currentPrim.p1_w.x + 
												baryCoord.z * currentPrim.p2_w.x;
					  
							curFragment.lightVec.y =	baryCoord.x * currentPrim.p0_w.y + 
												baryCoord.y * currentPrim.p1_w.y + 
												baryCoord.z * currentPrim.p2_w.y;

							curFragment.lightVec.z =	baryCoord.x * currentPrim.p0_w.z + 
												baryCoord.y * currentPrim.p1_w.z + 
												baryCoord.z * currentPrim.p2_w.z;
							curFragment.lightVec = glm::normalize (curFragment.lightVec);

							curFragment.position.x = i;
							curFragment.position.y = j;
							// Perspective correct interpolation for Z
							curFragment.position.z =	baryCoord.x * (1/currentPrim.p0.z) + 
													baryCoord.y * (1/currentPrim.p1.z) + 
													baryCoord.z * (1/currentPrim.p2.z);
							curFragment.position.z = 1/curFragment.position.z;

							// Compute antialiased colour.
							for (int m = -1; m < 2; m ++)
								for (int n = -1; n < 2; n ++)
								{
									baryCoord = calculateBarycentricCoordinate (currentPrim, glm::vec2 (i+(0.5f*m),j+(0.5f*n)));
									if (outline)
									{
										if (isBarycentricCoordInBounds (baryCoord))
											curFragment.color += baryCoord.x * currentPrim.c0 + 
														baryCoord.y * currentPrim.c1 + 
														baryCoord.z * currentPrim.c2;
										else
											curFragment.color += glm::vec3 (0);
									}
									else
									{
										curFragment.color += baryCoord.x * currentPrim.c0 + 
														baryCoord.y * currentPrim.c1 + 
														baryCoord.z * currentPrim.c2;	
									}
								}
							curFragment.color /= 9.0f;

							if (depthbuffer [(int)(j*resolution.x) + i].position.z > curFragment.position.z)
							{
								depthbuffer [(int)(j*resolution.x) + i] = curFragment;
							}
						}
					}
			}
  }
}

//TODO: Implement a fragment shader
__global__ void fragmentShadeKernel(fragment* depthbuffer, glm::vec2 resolution)
{
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);

  fragment curFragment;
  if (index < resolution.x*resolution.y)
	  curFragment = depthbuffer [index];

  __syncthreads ();

  if(x<resolution.x && y<resolution.y)
  {
	  // Lambertian shading.
	  float dotPdt = glm::dot (curFragment.normal, curFragment.lightVec);
	  dotPdt = max (dotPdt, 0.0f);
	  dotPdt = min (dotPdt, 1.0f);
	  curFragment.color *= dotPdt;

	  // Ambient colour.
	  if (curFragment.position.z < 1.0f)
		  curFragment.color += 0.1;

	  depthbuffer [index] = curFragment;
  }
}

//Writes fragment colors to the framebuffer
__global__ void render(glm::vec2 resolution, fragment* depthbuffer, glm::vec3* framebuffer)
{

  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);

  if(x<=resolution.x && y<=resolution.y)
  {
    framebuffer[index] = depthbuffer[index].color;
  }
}

// Wrapper for the __global__ call that sets up the kernel calls and does a ton of memory management
void cudaRasterizeCore(uchar4* PBOpos, glm::vec2 resolution, float frame, float* vbo, int vbosize, float* cbo, int cbosize, 
						int* ibo, int ibosize, float * nbo, int nbosize, bool &isFirstTime, const cbuffer &constantBuffer)
{
	int nPrims = ibosize / 3;
  // set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

  //set up framebuffer
  framebuffer = NULL;
  cudaMalloc((void**)&framebuffer, (int)resolution.x*(int)resolution.y*sizeof(glm::vec3));
  
  //set up depthbuffer
  depthbuffer = NULL;
  cudaMalloc((void**)&depthbuffer, (int)resolution.x*(int)resolution.y*sizeof(fragment));

  // set up constant buffer
  cbuffer*	device_constantBuffer = NULL;
  cudaMalloc((void**)&device_constantBuffer, sizeof(cbuffer));
  cudaMemcpy (device_constantBuffer, &constantBuffer, sizeof (cbuffer), cudaMemcpyHostToDevice);

  //kernel launches to black out accumulated/unaccumlated pixel buffers and clear our scattering states
  clearImage<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, framebuffer, glm::vec3(0,0,0));
  
  fragment frag;
  frag.color = glm::vec3(0,0,0);
  frag.normal = glm::vec3(0,0,0);
  frag.position = glm::vec3(0,0,10000);
  clearDepthBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer,frag);

  //------------------------------
  //memory stuff
  //------------------------------
  primitives = NULL;
  cudaMalloc((void**)&primitives, (ibosize/3)*sizeof(triangle));

  device_ibo = NULL;
  cudaMalloc((void**)&device_ibo, ibosize*sizeof(int));
  cudaMemcpy( device_ibo, ibo, ibosize*sizeof(int), cudaMemcpyHostToDevice);

  device_vbo = NULL;
  cudaMalloc((void**)&device_vbo, vbosize*sizeof(float));
  cudaMemcpy( device_vbo, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);
  float * device_vboW = NULL;
  cudaMalloc((void**)&device_vboW, vbosize*sizeof(float));
//  cudaMemcpy( device_vboW, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_cbo = NULL;
  cudaMalloc((void**)&device_cbo, cbosize*sizeof(float));
  cudaMemcpy( device_cbo, cbo, cbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_nbo = NULL;
  cudaMalloc((void**)&device_nbo, nbosize*sizeof(float));
  cudaMemcpy( device_nbo, nbo, nbosize*sizeof(float), cudaMemcpyHostToDevice);

  tileSize = 32;
  int primitiveBlocks = ceil(((float)vbosize/4)/((float)tileSize));

  //------------------------------
  //vertex shader
  //------------------------------
  vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, device_vboW, vbosize, device_nbo, nbosize, device_constantBuffer);
  checkCUDAError("Vertex shader failed!");
  cudaDeviceSynchronize();
  cudaFree (device_constantBuffer);
  device_constantBuffer = NULL;
  //------------------------------
  //primitive assembly
  //------------------------------
  primitiveBlocks = ceil(((float)nPrims)/((float)tileSize));
  primitiveAssemblyKernel<<<primitiveBlocks, tileSize>>>(device_vbo, device_vboW, vbosize, device_cbo, cbosize, device_ibo, ibosize, 
															device_nbo, nbosize, primitives);
  checkCUDAError("Primitive Assembly failed!");
  cudaDeviceSynchronize();
  cudaFree (device_vboW);
  device_vboW = NULL;
  //------------------------------
  // Map to Screen Space
  //------------------------------
  convertToScreenSpace<<<primitiveBlocks, tileSize, tileSize*sizeof (triangle)>>>(primitives,nPrims, resolution);
  checkCUDAError("Conversion to Screen Space failed!");
  cudaDeviceSynchronize();
  if (isFirstTime)
  {
	std::cout << "No. of tris: " <<nPrims << "\n";
  }
  //------------------------------
  // Mark back facing primitives and cull them.
  //------------------------------
  int * shouldCull = NULL;
  cudaMalloc((void**)&shouldCull, nPrims*sizeof(int));
  cudaMemset (shouldCull, 0, nPrims*sizeof (int));
  markBackFaces<<<primitiveBlocks, tileSize>>>(primitives, shouldCull, nPrims);
  checkCUDAError("Mark Back faces failed!");
  cudaDeviceSynchronize ();

  int * shouldCullOnHost = new int [nPrims];
  int * moveToIndex = new int [nPrims];
  memset (moveToIndex, 0, sizeof(int)*nPrims);
	/// ----- CPU/GPU Hybrid Stream Compaction ----- ///
	// Scan is done on the CPU, the actual compaction happens on the GPU.
	// ------------------------------------------------------------------
	// Copy the shouldCull array from device to host.
	cudaMemcpy (shouldCullOnHost, shouldCull, nPrims * sizeof (int), cudaMemcpyDeviceToHost);

	// Exclusive scan.
	for (int k = 1; k < nPrims; ++ k)
		moveToIndex [k] = moveToIndex [k-1] + shouldCullOnHost [k-1];
	// This is because the compactStream kernel should run on the whole, uncompacted array.
	// We'll set this to nPrims once compactStream has done its job.
	int compactednPrims = moveToIndex [nPrims-1] + shouldCullOnHost [nPrims-1];

	// Stream compaction. Compact the primitives into tmpPrims.
	triangle *tmpPrims = NULL;
	cudaMalloc ((void **)&tmpPrims, nPrims * sizeof (triangle));
	int * moveToOnDevice = NULL;
	cudaMalloc ((void **)&moveToOnDevice, nPrims * sizeof (int));
	cudaMemcpy (moveToOnDevice, moveToIndex, nPrims * sizeof (int), cudaMemcpyHostToDevice);
	compactStream<<<primitiveBlocks, tileSize>>>(primitives, tmpPrims, shouldCull, moveToOnDevice, nPrims);

	// Now set nPrims to the compacted array size, compactednPrims.
	nPrims = compactednPrims;
  cudaMemcpy (primitives, tmpPrims, sizeof(triangle)*nPrims, cudaMemcpyDeviceToDevice);

  cudaFree (tmpPrims);
  cudaFree (moveToOnDevice);
  cudaFree (shouldCull);
  delete [] moveToIndex;
  delete [] shouldCullOnHost;

  tmpPrims = NULL;	moveToOnDevice = NULL;	shouldCull = NULL;	moveToIndex = NULL;	shouldCullOnHost = NULL;
  cudaDeviceSynchronize();
  //-----------------------------------------
  // Rasterization - rasterize each primitive
  //-----------------------------------------
  time_t current = time (NULL);
  primitiveBlocks = ceil(((float)nPrims)/((float)tileSize));
//  for (int i = 0; i<(nPrims);  i++)
//	rasterizationKernel<<<fullBlocksPerGrid, threadsPerBlock, threadsPerBlock.x*threadsPerBlock.y*sizeof(fragment)>>>(primitives, i, depthbuffer, resolution);
  rasterizationKernelAlt<<<primitiveBlocks, tileSize>>>(primitives, nPrims, depthbuffer, resolution, outline);
  checkCUDAError("Rasterization failed!");
  cudaDeviceSynchronize();
  if (isFirstTime)
  {
//	  thrust
	  std::cout << "\nRasterized in " << difftime (time (NULL), current) << " seconds. No. of tris: " <<nPrims << "\n";
	  isFirstTime = false;
  }
  //------------------------------
  //fragment shader
  //------------------------------
  fragmentShadeKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(depthbuffer, resolution);
  checkCUDAError("Fragment shader failed!");
  cudaDeviceSynchronize();
  //------------------------------
  //write fragments to framebuffer
  //------------------------------
  render<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, framebuffer);
  sendImageToPBO<<<fullBlocksPerGrid, threadsPerBlock>>>(PBOpos, resolution, framebuffer);

  cudaDeviceSynchronize();

  kernelCleanup();

  checkCUDAError("Kernel failed!");
}

void kernelCleanup()
{
  cudaFree( primitives );
  cudaFree( device_vbo );
  cudaFree( device_cbo );
  cudaFree( device_ibo );
  cudaFree( framebuffer );
  cudaFree( depthbuffer );
}

