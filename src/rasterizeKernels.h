// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#ifndef RASTERIZEKERNEL_H
#define RASTERIZEKERNEL_H

#include <stdio.h>
#include <thrust/random.h>
#include <cuda.h>
#include <cmath>
#include "glm/glm.hpp"

#if CUDA_VERSION >= 5000
    #include <helper_math.h>
#else
    #include <cutil_math.h>
#endif

//-------------------------------
//--------DATA STRUCTURES--------
//-------------------------------
struct	cbuffer
{
	glm::mat4	model;
	glm::mat4	view;
	glm::mat4	projection;
	glm::mat4	modelIT;
	glm::vec4	lightPos;
};

void kernelCleanup();
void cudaRasterizeCore(uchar4* pos, glm::vec2 resolution, float frame, float* vbo, int vbosize, float* cbo, int cbosize, 
						int* ibo, int ibosize, float* nbo, int nbosize, bool &isFirstTime, const cbuffer &constantBuffer);

#endif //RASTERIZEKERNEL_H
