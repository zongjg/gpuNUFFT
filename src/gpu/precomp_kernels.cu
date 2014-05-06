#ifndef PRECOMP_KERNELS_CU
#define PRECOMP_KERNELS_CU

#include "precomp_kernels.hpp"
#include "cuda_utils.cuh"
#include "cuda_utils.hpp"

__global__ void assignSectorsKernel(DType* kSpaceTraj,
  IndType* assignedSectors,
  long coordCnt,
  bool is2DProcessing,
  GriddingND::Dimensions gridSectorDims)
{
  int t = threadIdx.x +  blockIdx.x *blockDim.x;
  IndType sector;

  while (t < coordCnt) 
  {
    if (is2DProcessing)
    {
      DType2 coord;
      coord.x = kSpaceTraj[t];
      coord.y = kSpaceTraj[t + coordCnt];
      IndType2 mappedSector = computeSectorMapping(coord,gridSectorDims);
      //linearize mapped sector
      sector = computeInd22Lin(mappedSector,gridSectorDims);		
    }
    else
    {
      DType3 coord;
      coord.x = kSpaceTraj[t];
      coord.y = kSpaceTraj[t + coordCnt];
      coord.z = kSpaceTraj[t + 2*coordCnt];
      IndType3 mappedSector = computeSectorMapping(coord,gridSectorDims);
      //linearize mapped sector
      sector = computeInd32Lin(mappedSector,gridSectorDims);		
    }

    assignedSectors[t] = sector;

    t = t+ blockDim.x*gridDim.x;
  }
}

void assignSectorsGPU(GriddingND::GriddingOperator* griddingOp, GriddingND::Array<DType>& kSpaceTraj, IndType* assignedSectors)
{
  IndType coordCnt = kSpaceTraj.count();

  dim3 block_dim(THREAD_BLOCK_SIZE);
  dim3 grid_dim(getOptimalGridDim((long)coordCnt,THREAD_BLOCK_SIZE));

  DType* kSpaceTraj_d;
  IndType* assignedSectors_d;

  if (DEBUG)
    printf("allocate and copy trajectory of size %d...\n",griddingOp->getImageDimensionCount()*coordCnt);
  allocateAndCopyToDeviceMem<DType>(&kSpaceTraj_d,kSpaceTraj.data,griddingOp->getImageDimensionCount()*coordCnt);

  if (DEBUG)
    printf("allocate and copy data of size %d...\n",coordCnt);
  allocateDeviceMem<IndType>(&assignedSectors_d,coordCnt);

  assignSectorsKernel<<<grid_dim,block_dim>>>(kSpaceTraj_d,
    assignedSectors_d,
    (long)coordCnt,
    griddingOp->is2DProcessing(),
    griddingOp->getGridSectorDims());

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at assignSectors thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));

  //get result from device 
  copyFromDevice<IndType>(assignedSectors_d,assignedSectors,coordCnt);

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at assignSectors thread synchronization 2: %s\n",cudaGetErrorString(cudaGetLastError()));

  freeTotalDeviceMemory(kSpaceTraj_d,assignedSectors_d,NULL);//NULL as stop
}

__global__ void sortArraysKernel(GriddingND::IndPair* assignedSectorsAndIndicesSorted,
  IndType* assignedSectors, 
  IndType* dataIndices,
  DType* kSpaceTraj,
  DType* trajSorted,
  DType* densCompData,
  DType* densData,
  bool is3DProcessing,
  long coordCnt)
{
  int t = threadIdx.x +  blockIdx.x *blockDim.x;

  while (t < coordCnt) 
  {
    trajSorted[t] = kSpaceTraj[assignedSectorsAndIndicesSorted[t].first];
    trajSorted[t + 1*coordCnt] = kSpaceTraj[assignedSectorsAndIndicesSorted[t].first + 1*coordCnt];
    if (is3DProcessing)
      trajSorted[t + 2*coordCnt] = kSpaceTraj[assignedSectorsAndIndicesSorted[t].first + 2*coordCnt];

    //sort density compensation
    if (densCompData != NULL)
      densData[t] = densCompData[assignedSectorsAndIndicesSorted[t].first];

    dataIndices[t] = assignedSectorsAndIndicesSorted[t].first;
    assignedSectors[t] = assignedSectorsAndIndicesSorted[t].second;		

    t = t+ blockDim.x*gridDim.x;
  }
}

void sortArrays(GriddingND::GriddingOperator* griddingOp, 
  std::vector<GriddingND::IndPair> assignedSectorsAndIndicesSorted,
  IndType* assignedSectors, 
  IndType* dataIndices,
  GriddingND::Array<DType>& kSpaceTraj,
  DType* trajSorted,
  DType* densCompData,
  DType* densData)
{
  IndType coordCnt = kSpaceTraj.count();
  dim3 block_dim(THREAD_BLOCK_SIZE);
  dim3 grid_dim(getOptimalGridDim((long)coordCnt,THREAD_BLOCK_SIZE));

  DType* kSpaceTraj_d;
  GriddingND::IndPair* assignedSectorsAndIndicesSorted_d;
  IndType* assignedSectors_d;
  IndType* dataIndices_d;
  DType* trajSorted_d;
  DType* densCompData_d = NULL;
  DType* densData_d = NULL;

  //Trajectory and sorted result 
  allocateAndCopyToDeviceMem<DType>(&kSpaceTraj_d,kSpaceTraj.data,griddingOp->getImageDimensionCount()*coordCnt);
  allocateDeviceMem<DType>(&trajSorted_d,griddingOp->getImageDimensionCount()*coordCnt);

  //Assigned sorted sectors and data indices and result
  allocateAndCopyToDeviceMem<GriddingND::IndPair>(&assignedSectorsAndIndicesSorted_d,assignedSectorsAndIndicesSorted.data(),coordCnt);
  allocateDeviceMem<IndType>(&assignedSectors_d,coordCnt);	 
  allocateDeviceMem<IndType>(&dataIndices_d,coordCnt);	 

  //Density compensation data and sorted result
  if (densCompData != NULL)
  {
    allocateAndCopyToDeviceMem<DType>(&densCompData_d,densCompData,coordCnt);
    allocateDeviceMem<DType>(&densData_d,coordCnt);
  }

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at sortArrays thread synchronization 0: %s\n",cudaGetErrorString(cudaGetLastError()));

  sortArraysKernel<<<grid_dim,block_dim>>>( assignedSectorsAndIndicesSorted_d,
    assignedSectors_d, 
    dataIndices_d,
    kSpaceTraj_d,
    trajSorted_d,
    densCompData_d,
    densData_d,
    griddingOp->is3DProcessing(),
    (long)coordCnt);
  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at sortArrays thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));

  copyFromDevice<IndType>(assignedSectors_d,assignedSectors,coordCnt);
  copyFromDevice<IndType>(dataIndices_d,dataIndices,coordCnt);
  copyFromDevice<DType>(trajSorted_d,trajSorted,griddingOp->getImageDimensionCount()*coordCnt);
  if (densCompData != NULL)
    copyFromDevice<DType>(densData_d,densData,coordCnt);

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at sortArrays thread synchronization 2: %s\n",cudaGetErrorString(cudaGetLastError()));

  freeTotalDeviceMemory(kSpaceTraj_d,assignedSectorsAndIndicesSorted_d,assignedSectors_d,dataIndices_d,trajSorted_d,densCompData_d,densData_d,NULL);//NULL as stop
}

__global__ void selectOrderedGPUKernel(DType2* data, DType2* data_sorted, IndType* dataIndices, IndType offset, IndType N)
{
  int t = threadIdx.x;
  
  while (t < offset) 
  {
    data_sorted[t+blockIdx.x*offset] = data[dataIndices[t]+blockIdx.x*offset];

    t = t + blockDim.x;
  }
}

DType2* selectOrderedGPU(GriddingND::Array<DType2>& dataArray, GriddingND::Array<IndType> dataIndices,int offset)
{
  dim3 block_dim(THREAD_BLOCK_SIZE);
  // one thread block for each channel 
  dim3 grid_dim(dataArray.dim.channels); 

  DType2* data_d, *data_sorted_d;
  IndType* dataIndices_d;

  if (DEBUG)
    printf("allocate and copy data of size %d...\n",dataArray.count());
  allocateAndCopyToDeviceMem<DType2>(&data_d,dataArray.data,dataArray.count());

  if (DEBUG)
    printf("allocate and copy output data of size %d...\n",dataArray.count());
  allocateDeviceMem<DType2>(&data_sorted_d,dataArray.count());
  
  if (DEBUG)
    printf("allocate and copy data indices of size %d...\n",dataIndices.count());
  allocateAndCopyToDeviceMem<IndType>(&dataIndices_d,dataIndices.data,dataIndices.count());
  
  selectOrderedGPUKernel<<<grid_dim,block_dim>>>(data_d,data_sorted_d,dataIndices_d,offset,dataArray.count());

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at selectOrderedGPU thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));

  freeTotalDeviceMemory(data_d, dataIndices_d,NULL);//NULL as stop

  return data_sorted_d;
}

__global__ void writeOrderedGPUKernel(DType2* data, DType2* data_sorted, IndType* dataIndices, IndType offset, IndType N)
{
  int t = threadIdx.x;
  
  while (t < offset) 
  {
    data[dataIndices[t]+blockIdx.x*offset] = data_sorted[t+blockIdx.x*offset];

    t = t + blockDim.x;
  }
}


void writeOrderedGPU(GriddingND::Array<DType2>& destArray, GriddingND::Array<IndType> dataIndices, CufftType* sortedArray, int offset)
{
  dim3 block_dim(THREAD_BLOCK_SIZE);
  // one thread block for each channel 
  dim3 grid_dim(destArray.dim.channels); 

  DType2* data_d;
  CufftType* data_sorted_d;
  IndType* dataIndices_d;

  if (DEBUG)
    printf("allocate and copy data of size %d...\n",destArray.count());
  allocateDeviceMem<DType2>(&data_d,destArray.count());

  if (DEBUG)
    printf("allocate and copy output data of size %d...\n",destArray.count());
  allocateAndCopyToDeviceMem<CufftType>(&data_sorted_d,sortedArray,destArray.count());
  
  if (DEBUG)
    printf("allocate and copy data indices of size %d...\n",dataIndices.count());
  allocateAndCopyToDeviceMem<IndType>(&dataIndices_d,dataIndices.data,dataIndices.count());
  
  writeOrderedGPUKernel<<<grid_dim,block_dim>>>(data_d,data_sorted_d,dataIndices_d,offset,destArray.count());

  if (DEBUG && (cudaThreadSynchronize() != cudaSuccess))
    printf("error: at selectOrderedGPU thread synchronization 1: %s\n",cudaGetErrorString(cudaGetLastError()));

  copyFromDevice<DType2>(data_d,destArray.data,destArray.count());

  freeTotalDeviceMemory(data_sorted_d, data_d, dataIndices_d,NULL);//NULL as stop
}

#endif
