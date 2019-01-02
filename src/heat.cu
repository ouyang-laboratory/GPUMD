/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/




#include "common.cuh"
#include "heat.cuh"
#include "integrate.cuh"
#include "ensemble.cuh"
#include "memory.cuh"
#include "atom.cuh"
#include "error.cuh"
#include "parameters.cuh"

#define FILE_NAME_LENGTH      200
#define DIM                   3
#ifdef USE_DP
    #define ZERO  0.0
    #define K_B   8.617343e-5
#else
    #define ZERO  0.0f
    #define K_B   8.617343e-5f
#endif




// allocate memory used for recording group temperatures 
// and energies of the heat source and sink
void Heat::preprocess_heat(Parameters *para)
{
    if (sample)
    {
        // The last 2 data are the energy changes of the source and sink
        int num = (para->number_of_groups + 2) 
                * (para->number_of_steps / sample_interval);
        MY_MALLOC(group_temp, real, num);
    }
}




static __device__ void warp_reduce(volatile real *s, int t) 
{
    s[t] += s[t + 32]; s[t] += s[t + 16]; s[t] += s[t + 8];
    s[t] += s[t + 4];  s[t] += s[t + 2];  s[t] += s[t + 1];
}




// sample block temperature (kernel)
static __global__ void find_group_temp
(
    int  *g_group_size,
    int  *g_group_size_sum,
    int  *g_group_contents,
    real *g_mass,
    real *g_vx,
    real *g_vy,
    real *g_vz,
    real *g_group_temp
)
{
    // <<<number_of_groups, 256>>> (one CUDA block for one group of atoms)

    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int group_size = g_group_size[bid];
    int offset = g_group_size_sum[bid];
    int number_of_patches = (group_size - 1) / 256 + 1;
    __shared__ real s_ke[256];
    s_ke[tid] = ZERO;

    for (int patch = 0; patch < number_of_patches; patch++)
    {
        int k = tid + patch * 256;
        if (k < group_size)
        {
            int n = g_group_contents[offset + k]; // particle index
            real vx = g_vx[n];
            real vy = g_vy[n];
            real vz = g_vz[n];
            s_ke[tid] += g_mass[n] * (vx * vx + vy * vy + vz * vz);
        }
    }
    __syncthreads();

    if (tid <  128) { s_ke[tid] += s_ke[tid + 128]; }  __syncthreads();
    if (tid <   64) { s_ke[tid] += s_ke[tid + 64];  }  __syncthreads();
    if (tid <   32) { warp_reduce(s_ke, tid);       }  
    if (tid ==   0) {g_group_temp[bid] = s_ke[0] / (DIM * K_B * group_size);}
}




// sample block temperature (wrapper)
void Heat::sample_block_temperature
(int step, Parameters *para, Atom *atom, Integrate *integrate)
{
    if (sample)
    {
        if (step % sample_interval == 0)
        {
            int Ng = para->number_of_groups;
            int offset = (step / sample_interval) * (Ng + 2);
      
            // block temperatures
            real *temp_gpu;
            CHECK(cudaMalloc((void**)&temp_gpu, sizeof(real) * Ng));
            int  *group_size = atom->group_size;
            int  *group_size_sum = atom->group_size_sum;
            int  *group_contents = atom->group_contents;
            real *mass = atom->mass;
            real *vx = atom->vx;
            real *vy = atom->vy;
            real *vz = atom->vz;
            find_group_temp<<<Ng, 256>>>
            (
                group_size, group_size_sum, group_contents, 
                mass, vx, vy, vz, temp_gpu
            );
            #ifdef DEBUG
                CHECK(cudaDeviceSynchronize());
                CHECK(cudaGetLastError());
            #endif
            CHECK(cudaMemcpy(group_temp+offset, temp_gpu, 
                sizeof(real)*Ng, cudaMemcpyDeviceToHost));
            CHECK(cudaFree(temp_gpu));

            // energies of the heat source and sink
            group_temp[offset + Ng]     
                = integrate->ensemble->energy_transferred[0];
            group_temp[offset + Ng + 1] 
                = integrate->ensemble->energy_transferred[1];
        }
    }
}




// Output block temperatures and energies of the heat source and sink; 
// free the used memory
void Heat::postprocess_heat
(char *input_dir, Parameters *para, Integrate *integrate)
{
    if (sample)
    {
        int Nt = para->number_of_steps / sample_interval;
        int Ng = para->number_of_groups;
        char file_temperature[FILE_NAME_LENGTH];
        strcpy(file_temperature, input_dir);
        strcat(file_temperature, "/temperature.out");
        FILE *fid = fopen(file_temperature, "a");
        for (int nt = 0; nt < Nt; nt++)
        {
            int offset = nt * (Ng + 2);
            int number_of_data = Ng + 2;
            for (int k = 0; k < number_of_data; k++) 
            {
                fprintf(fid, "%15.6e", group_temp[offset + k]);
            }
            fprintf(fid, "\n");
        }
        fflush(fid);
        MY_FREE(group_temp); // allocated in preprocess_heat
    }
}




