#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/sort.h>
#include <thrust/device_ptr.h>
#include <thrust/partition.h>
#include <glm/gtc/matrix_inverse.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include "optimizations.h"
#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static PathSegment * cache_dev_paths = NULL;
static ShadeableIntersection * cache_dev_intersections = NULL;
static bool cache_valid = false;
static int cache_num_active_paths = 0;

void pathtraceInit(Scene *scene) {
	hst_scene = scene;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	cudaMalloc(&cache_dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
	cudaMalloc(&cache_dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(cache_dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(cache_dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(cache_dev_intersections);
	// TODO: clean up any extra device memory you created

	checkCUDAError("pathtraceFree");
}

__device__ glm::vec3 concentricSampleDisc(const float u, const float v) {
	// Map random inputs to [-1, 1]^2
	glm::vec2 point = glm::vec2(u, v);
	glm::vec2 offset = (2.0f * point) - glm::vec2(1, 1);

	// Handle origin case
	if (offset.x == 0 && offset.y == 0) {
		return glm::vec3(0, 0, 0);
	}

	// Apply concentric mapping
	float theta;
	float r;

	if (fabsf(offset.x) > fabsf(offset.y)) {
		r = offset.x;
		theta = (PI / 4) * (offset.x / offset.y);
	}
	else {
		r = offset.y;
		theta = (PI / 2) - (PI / 4) * (offset.x / offset.y);
	}

	// Create the point, reuse our input holder.
	point = r * glm::vec2(cosf(theta), sinf(theta));

	return glm::vec3(point.x, point.y, 0);
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, segment.remainingBounces);
		thrust::uniform_real_distribution<float> u0_5(-0.5f, 0.5f);
		thrust::uniform_real_distribution<float> u1_0(0, 1);

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		float xjitter = 0;
		float yjitter = 0;

		if (ANTIALIASING) {
			xjitter = u0_5(rng);
			yjitter = u0_5(rng);
		}

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + xjitter - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + yjitter - (float)cam.resolution.y * 0.5f)
		);

		if (DEPTH_OF_FIELD) {
			// Inspired by PBRT3 6.2.3
			// Sample point on Lens
			glm::vec3 lensPoint = DOF_LENS_RADIUS * concentricSampleDisc(u1_0(rng), u1_0(rng));

			// Compute Point on plane of focus
			float ft = glm::abs(DOF_FOCAL_DIST / segment.ray.direction.z);
			glm::vec3 focusPoint = ft * segment.ray.direction;

			// Update ray for effect of lens
			segment.ray.origin += lensPoint;
			segment.ray.direction = glm::normalize(focusPoint - lensPoint);
		}

		if (MOTION_BLUR) {
			segment.ray.time = u1_0(rng);
		}

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__device__ glm::mat4 buildTransformationMatrix(const glm::vec3 & translation, const glm::vec3 & rotation, const glm::vec3 & scale) {
	glm::mat4 translationMat = glm::translate(glm::mat4(), translation);
	glm::mat4 rotationMat = glm::rotate(glm::mat4(), rotation.x * (float)PI / 180, glm::vec3(1, 0, 0));
	rotationMat = rotationMat * glm::rotate(glm::mat4(), rotation.y * (float)PI / 180, glm::vec3(0, 1, 0));
	rotationMat = rotationMat * glm::rotate(glm::mat4(), rotation.z * (float)PI / 180, glm::vec3(0, 0, 1));
	glm::mat4 scaleMat = glm::scale(glm::mat4(), scale);
	return translationMat * rotationMat * scaleMat;
}


// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];
			glm::mat4 oldInvTransform;
			glm::mat4 oldInvTranspose;

			if (MOTION_BLUR) {
				// Apply transform to inverseTransform matrix to account for velocity
				glm::vec3 newTranslate = geom.translation + (pathSegment.ray.time * geom.velocity);
				glm::mat4 newTransform = buildTransformationMatrix(newTranslate, geom.rotation, geom.scale);
				oldInvTransform = geom.inverseTransform;
				oldInvTranspose = geom.invTranspose;
				geom.inverseTransform = glm::inverse(newTransform);
				geom.invTranspose = glm::inverseTranspose(newTransform);
			}

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == TRIANGLE)
			{
				t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}

			if (MOTION_BLUR) {
				geom.inverseTransform = oldInvTransform;
				geom.invTranspose = oldInvTranspose;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		if (pathSegments[idx].remainingBounces == 0) return;

		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		    // Set up the RNG
		    // LOOK: this is how you use thrust's RNG! Please look at
		    // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegments[idx].remainingBounces);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
				pathSegments[idx].remainingBounces = 0; // If you hit a light, stop!
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				// Errybody bounce bounce b-b-bounce
				scatterRay(
					pathSegments[idx],
					getPointOnRay(pathSegments[idx].ray, intersection.t),
					intersection.surfaceNormal,
					material,
					rng);
			}
		}
		else {
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.

			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}


// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct is_not_null_intersection {
	__device__ bool operator()(const ShadeableIntersection & x) const {
		return (x.t != -1.0f);
	}
};

struct bounces_remaining {
	__device__ bool operator()(const PathSegment & x) const {
		return (x.remainingBounces != 0);
	}
};

struct material_idx_less_than {
	__device__ bool operator()(const ShadeableIntersection & lhs, const ShadeableIntersection & rhs) const {
		return (lhs.materialId < rhs.materialId);
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int num_active_paths = num_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	bool iterationComplete = false;
	while (!iterationComplete) {
		cudaEventRecord(start);
		dim3 numblocksPathSegmentTracing = (num_active_paths + blockSize1d - 1) / blockSize1d;

		if (CACHE_ENABLED && depth == 0 && cache_valid) {
			// Use the cached version of the first loop.
			// This will always be the same
			cudaMemcpy(dev_intersections, cache_dev_intersections, pixelcount * sizeof(ShadeableIntersection), ::cudaMemcpyDeviceToDevice);
			checkCUDAError("Cache load");
			cudaDeviceSynchronize();
		}
		else {
			// Cache is either invalid or not depth 0
			// Clear previous intersections and calculate next set
			cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_active_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();

			if (CACHE_ENABLED && !cache_valid) {
				// Cache these values if the flag is not set
				cudaMemcpy(cache_dev_intersections, dev_intersections, pixelcount * sizeof(ShadeableIntersection), ::cudaMemcpyDeviceToDevice);
				cache_valid = true;
			}
		}

		depth++;

		// Sort by Material IDX. This will improve cache reuse on Shader stage
		// Also reduces branch divergence in shader!
		if (PRESHADER_MATERIAL_SORT) {
			thrust::sort_by_key(
				thrust::device_ptr<ShadeableIntersection>(dev_intersections),
				thrust::device_ptr<ShadeableIntersection>(dev_intersections + num_active_paths),
				thrust::device_ptr<PathSegment>(dev_paths),
				material_idx_less_than());
		}

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	    // evaluating the BSDF.
	    // Start off with just a big kernel that handles all the different
	    // materials you have in the scenefile.
	    // TODO: compare between directly shading the path segments and shading
	    // path segments that have been reshuffled to be contiguous in memory.
		shadeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_active_paths,
			dev_intersections,
			dev_paths,
			dev_materials
			);
		cudaDeviceSynchronize();

		if (POSTSHADER_PARTITION) {
			// Remove all null intersections. Returns new end interator.
			dev_path_end = thrust::partition(
				thrust::device_ptr<PathSegment>(dev_paths),
				thrust::device_ptr<PathSegment>(dev_path_end),
				thrust::device_ptr<ShadeableIntersection>(dev_intersections),
				is_not_null_intersection()).get();

			// Remove any paths that have hit their bounce limit
			dev_path_end = thrust::partition(
				thrust::device_ptr<PathSegment>(dev_paths),
				thrust::device_ptr<PathSegment>(dev_path_end),
				bounces_remaining()).get();

			// Update num_paths
			num_active_paths = dev_path_end - dev_paths;
		}

		// Run until all paths are done OR the trace depth has been reached.
		if (num_active_paths == 0 || depth >= traceDepth) {
			iterationComplete = true;
		}

		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
		float milliseconds = 0;
		cudaEventElapsedTime(&milliseconds, start, stop);

		printf("%d\t%d\t%f\n", depth, num_active_paths, milliseconds);
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

void pathtraceInvalidateCache()
{
	cache_valid = false;
}


void generateTerrainGeometries() {

}

float tgDensityFunction(float3 ws) {
	float density = 0.0f;

	density = -ws.y;

	return density;
}