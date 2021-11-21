#include <iostream>
#include <cufft.h>

// Rename float2 type to complex number
typedef float2 Complex;

// Define global constants in host memory
constexpr unsigned BLOCK_DIM = 1 << 3;
constexpr unsigned SIGNAL_LENGTH = 1 << 5;
constexpr unsigned FILTER_LENGTH = 1 << 3;
constexpr unsigned FIRST_HALF_FILTER_LENGTH = FILTER_LENGTH / 2;
constexpr unsigned SIGNAL_BYTES = SIGNAL_LENGTH * sizeof(Complex);
constexpr unsigned FILTER_BYTES = FILTER_LENGTH * sizeof(Complex);
constexpr unsigned SECOND_HALF_FILTER_LENGTH = FILTER_LENGTH - FIRST_HALF_FILTER_LENGTH;
constexpr unsigned PADDED_INPUT_DATA_LENGTH = SIGNAL_LENGTH + SECOND_HALF_FILTER_LENGTH;
constexpr unsigned PADDED_INPUT_DATA_BYTES = PADDED_INPUT_DATA_LENGTH * sizeof(Complex);
constexpr unsigned FIRST_HALF_FILTER_BYTES = FIRST_HALF_FILTER_LENGTH * sizeof(Complex);
constexpr unsigned SECOND_HALF_FILTER_BYTES = SECOND_HALF_FILTER_LENGTH * sizeof(Complex);

// Define operations on complex numbers
__device__ Complex ComplexScaling(Complex a, float s)
{
    Complex c;
    c.x = s * a.x;
    c.y = s * a.y;
    return c;
}

__host__ __device__ Complex ComplexAddition(Complex a, Complex b)
{
    Complex c;
    c.x = a.x + b.x;
    c.y = a.y + b.y;
    return c;
}

__host__ __device__ Complex ComplexMultiplication(Complex a, Complex b)
{
    Complex c;
    c.x = a.x * b.x - a.y * b.y;
    c.y = a.x * b.y + a.y * b.x;
    return c;
}

__global__ void ComplexMultiplicationAndScaling(Complex *a, const Complex *b)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    for (int i = threadID; i < PADDED_INPUT_DATA_LENGTH; i += numThreads) {
        a[i] = ComplexScaling(ComplexMultiplication(a[i], b[i]), 1.0f / PADDED_INPUT_DATA_LENGTH);
    }
}

// Define custom 1D FFT convolution calculation kernel
__global__ void CustomConvolutionKernel(const Complex *signal, const Complex *filter, Complex *filteredSignal) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    __shared__ Complex tile[BLOCK_DIM];
    tile[threadIdx.x] = signal[i];
    __syncthreads();
    Complex signalValue, filteredValue;
    filteredValue.x = 0.0f;
    filteredValue.y = 0.0f;
    int start = i - FIRST_HALF_FILTER_LENGTH;
    for (int j = 0; j < FILTER_LENGTH; ++j) {
        if (start + j >= 0 && start + j < SIGNAL_LENGTH) {
            signalValue = (start + j >= blockIdx.x * blockDim.x && start + j < (blockIdx.x + 1) * blockDim.x)
                          ? (tile[threadIdx.x + j - FIRST_HALF_FILTER_LENGTH])
                          : (signal[start + j]);
            filteredValue = ComplexAddition(filteredValue, ComplexMultiplication(signalValue, filter[j]));
        }
    }
    filteredSignal[i] = filteredValue;
}


int main() {
    std::cout << "CUSTOM DEVICE KERNEL EXECUTION\n";

    // Declare pointers to input and output data on host
    Complex *hostFilter = nullptr;
    Complex *hostSignal = nullptr;
    Complex *hostFilteredSignal = nullptr;

    // Declare pointers to input and output data on device
    Complex *deviceFilter = nullptr;
    Complex *deviceSignal = nullptr;
    Complex *deviceFilteredSignal = nullptr;

    // Allocate pinned host memory for input and output data
    cudaMallocHost((void **) &hostSignal, PADDED_INPUT_DATA_BYTES);
    cudaMallocHost((void **) &hostFilter, PADDED_INPUT_DATA_BYTES);
    cudaMallocHost((void **) &hostFilteredSignal, PADDED_INPUT_DATA_BYTES);

    // Allocate device memory for input and output data
    cudaMalloc((void **) &deviceSignal, PADDED_INPUT_DATA_BYTES);
    cudaMalloc((void **) &deviceFilter, PADDED_INPUT_DATA_BYTES);
    cudaMalloc((void **) &deviceFilteredSignal, PADDED_INPUT_DATA_BYTES);

    // Assign signal data on host
    for (unsigned i = 0; i < SIGNAL_LENGTH; ++i) {
        hostSignal[i].x = rand() % RAND_MAX;
        hostSignal[i].y = rand() % RAND_MAX;
    }

    // Assign filter data on host
    for (unsigned j = 0; j < FILTER_LENGTH; ++j) {
        hostFilter[j].x = rand() % RAND_MAX;
        hostFilter[j].y = rand() % RAND_MAX;
    }

    // Pad signal data on host
    cudaMemset(hostSignal + SIGNAL_LENGTH, 0, PADDED_INPUT_DATA_BYTES - SIGNAL_BYTES);
    
    // Pad filter data on host
    Complex *hostFilterCopy = nullptr;
    cudaMallocHost((void **) &hostFilterCopy, PADDED_INPUT_DATA_BYTES);
    cudaMemcpy(hostFilterCopy, hostFilter + FIRST_HALF_FILTER_LENGTH, SECOND_HALF_FILTER_BYTES, cudaMemcpyHostToHost);
    cudaMemset(hostFilterCopy + SECOND_HALF_FILTER_LENGTH, 0, PADDED_INPUT_DATA_BYTES - FILTER_BYTES);
    cudaMemcpy(hostFilterCopy + PADDED_INPUT_DATA_LENGTH - FIRST_HALF_FILTER_LENGTH, hostFilter, FIRST_HALF_FILTER_BYTES, cudaMemcpyHostToHost);
    hostFilter = hostFilterCopy;

    // Copy padded input data from host to device
    cudaMemcpy(deviceSignal, hostSignal, PADDED_INPUT_DATA_BYTES, cudaMemcpyHostToDevice);
    cudaMemcpy(deviceFilter, hostFilter, PADDED_INPUT_DATA_BYTES, cudaMemcpyHostToDevice);

    // Declare event variables to measure execution time
    float elapsedTime;
    cudaEvent_t startTime, endTime;

    // Create events to measure execution time
    cudaEventCreate(&startTime);
    cudaEventCreate(&endTime);

    // Define kernel configuration variables
    dim3 blockDim(BLOCK_DIM);
    dim3 gridDim((PADDED_INPUT_DATA_LENGTH - 1) / BLOCK_DIM + 1);

    // Launch custom 1D FFT convolution calculation kernel on device and record start of execution
    CustomConvolutionKernel<<<gridDim, blockDim>>>(deviceSignal, deviceFilter, deviceFilteredSignal);

    // Record start of execution
    cudaEventRecord(startTime, 0);
    
    // Synchronize start of execution call
    cudaEventSynchronize(startTime);

    // Record end of execution
    cudaEventRecord(endTime, 0);

    // Synchronize end of execution call
    cudaEventSynchronize(endTime);

    // Transfer output data from device to host
    cudaMemcpy(hostFilteredSignal, deviceFilteredSignal, PADDED_INPUT_DATA_BYTES, cudaMemcpyDeviceToHost);

    // Print output data on host
    std::cout << "Filtered Signal:\n";
    for (unsigned i = 0; i < PADDED_INPUT_DATA_LENGTH; ++i) {
        std::cout << hostFilteredSignal[i].x << ' ' << hostFilteredSignal[i].y << '\n';
    }
    std::cout << '\n';

    // Calculate and print elapsed time
    cudaEventElapsedTime(&elapsedTime, startTime, endTime);
    std::cout << "Elapsed Time on Device: " << elapsedTime << " ms\n";

    // Destroy events
    cudaEventDestroy(startTime);
    cudaEventDestroy(endTime);

    std::cout << "\nLIBRARY DEVICE KERNEL EXECUTION\n";

    // Create computation plan
    cufftHandle plan;
    cufftPlan1d(&plan, PADDED_INPUT_DATA_LENGTH, CUFFT_C2C, 1);

    // Create events to measure execution time
    cudaEventCreate(&startTime);
    cudaEventCreate(&endTime);

    // Apply forward Discrete Fourier Transform to input data on device
    cufftExecC2C(plan, (cufftComplex *)deviceSignal, (cufftComplex *)deviceSignal, CUFFT_FORWARD);
    cufftExecC2C(plan, (cufftComplex *)deviceFilter, (cufftComplex *)deviceFilter, CUFFT_FORWARD);

    // Multiply and normalize the complex frequency coefficients on device
    ComplexMultiplicationAndScaling<<<gridDim, blockDim>>>(deviceSignal, deviceFilter);

    // Apply inverse Discrete Fourier Transform to input data on device
    cufftExecC2C(plan, (cufftComplex *)deviceSignal, (cufftComplex *)deviceSignal, CUFFT_INVERSE);

    // Record start of execution
    cudaEventRecord(startTime, 0);
    
    // Synchronize start of execution call
    cudaEventSynchronize(startTime);

    // Record end of execution
    cudaEventRecord(endTime, 0);

    // Synchronize end of execution call
    cudaEventSynchronize(endTime);

    // Transfer output data from device to host
    cudaMemcpy(hostFilteredSignal, deviceSignal, PADDED_INPUT_DATA_BYTES, cudaMemcpyDeviceToHost);

    // Print output data on host
    std::cout << "Filtered Signal:\n";
    for (unsigned i = 0; i < PADDED_INPUT_DATA_LENGTH; ++i) {
        std::cout << hostFilteredSignal[i].x << ' ' << hostFilteredSignal[i].y << '\n';
    }
    std::cout << '\n';

    // Calculate and print elapsed time
    cudaEventElapsedTime(&elapsedTime, startTime, endTime);
    std::cout << "Elapsed Time on Device: " << elapsedTime << " ms\n";

    // Destroy events
    cudaEventDestroy(startTime);
    cudaEventDestroy(endTime);

    // Destroy computation plan
    cufftDestroy(plan);

    // Free device memory
    cudaFree(deviceSignal);
    cudaFree(deviceFilter);
    cudaFree(deviceFilteredSignal);

    // Free pinned host memory
    cudaFreeHost(hostSignal);
    cudaFreeHost(hostFilter);
    cudaFreeHost(hostFilteredSignal);

    // Check for errors
    unsigned exitStatus = EXIT_SUCCESS;
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        std::cout << "Error: " << cudaGetErrorString(err) << '\n';
        exitStatus = EXIT_FAILURE;
    }
    
    return exitStatus;
}