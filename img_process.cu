#include "img_process.hpp"

//#define __OUTPUT_PIX__
#define BLOCK_SIZE 128
__constant__ __device__ float lTable_const[1064];
__constant__ __device__ float mr_const[3];
__constant__ __device__ float mg_const[3];
__constant__ __device__ float mb_const[3];

#define FATAL(msg, ...) \
    do {\
        fprintf(stderr, "[%s:%d] "msg"\n", __FILE__, __LINE__, ##__VA_ARGS__);\
        exit(-1);\
    } while(0)

img_process::img_process()
{
}

img_process::~img_process()
{
}

__global__ void convert_to_luv_gpu_kernel(float *in_img, float *out_img, int n, bool use_rgb)
{
	float r, g, b, l, u, v, x, y, z, lt;

	unsigned int pos = threadIdx.x + (blockDim.x * blockIdx.x);
	if (!(pos < n))
		return;

	if (use_rgb) {
		r = in_img[(3 * pos)];
		g = in_img[(3 * pos) + 1];
		b = in_img[(3 * pos) + 2];
	} else {
		b = in_img[(3 * pos)];
		g = in_img[(3 * pos) + 1];
		r = in_img[(3 * pos) + 2];
	}

	x = (mr_const[0] * r) + (mg_const[0] * g) + (mb_const[0] * b);
	y = (mr_const[1] * r) + (mg_const[1] * g) + (mb_const[1] * b);
	z = (mr_const[2] * r) + (mg_const[2] * g) + (mb_const[2] * b);

	float maxi = 1.0f / 270;
	float minu = -88.0f * maxi;
	float minv = -134.0f * maxi;
	float un = 0.197833f;
	float vn = 0.468331f;

	lt = lTable_const[y * 1024];
	l = lt; z = 1/(x + (15 * y) + (3 * z) + (float)1e-35);
	u = lt * (13 * 4 * x * z - 13 * un) - minu;
	v = lt * (13 * 9 * y * z - 13 * vn) - minv;

	out_img[3 * pos] = l;
	out_img[(3 * pos) + 1] = u;
	out_img[(3 * pos) + 2] = v;
}


void img_process::rgb2luv(cv::Mat& in_img, cv::Mat& out_img, float nrm, bool useRGB)
{
	CV_Assert( in_img.type() == CV_32FC3);
	rgb2luv_setup(nrm);
	float *R, *G, *B;
	if(!useRGB) /// default RGB order
		R = in_img.ptr<float>(0), G = in_img.ptr<float>(0) + 1, B = in_img.ptr<float>(0) + 2;
	else /// use opencv's built in RGB order:
		B = in_img.ptr<float>(0), G = in_img.ptr<float>(0) + 1, R = in_img.ptr<float>(0) + 2;
	cv::Mat res_img(in_img.rows, in_img.cols, CV_32FC3);
	out_img = res_img;
	int n = in_img.rows * in_img.cols;
	/// xma opencv order of each channel:
	/// get l,u,v pointer and r g b pointer
	float *L=out_img.ptr<float>(0), *U=out_img.ptr<float>(0) + 1, *V=out_img.ptr<float>(0) + 2;
	for( int i=0; i<n; i++ )
	{
		float r, g, b, x, y, z, l;
		r=*R; g=*G; b=*B;
		R += 3;
		G += 3;
		B += 3;
		x = mr[0]*r + mg[0]*g + mb[0]*b;
		y = mr[1]*r + mg[1]*g + mb[1]*b;
		z = mr[2]*r + mg[2]*g + mb[2]*b;
		l = lTable[static_cast<int>((y*1024))];
		*(L) = l; z = 1/(x + 15*y + 3*z + (float)1e-35);
		*(U) = l * (13*4*x*z - 13*un) - minu;
		*(V) = l * (13*9*y*z - 13*vn) - minv;
		L += 3;
		U += 3;
		V += 3;
	}
	return;
}


void img_process::rgb2luv_gpu(cv::Mat& in_img, cv::Mat& out_img, float nrm, bool useRGB)
{
	CV_Assert(in_img.type() == CV_32FC3);
	rgb2luv_setup_gpu(nrm);

	cv::Mat res_img(in_img.rows, in_img.cols, CV_32FC3);
	int n = in_img.rows * in_img.cols;

	float *dev_input_img, *dev_output_img;
	unsigned int img_size_total = in_img.step * in_img.rows;
	cudaError_t cuda_ret;

	//Allocate device memory
	cuda_ret = cudaMalloc(&dev_input_img, img_size_total * sizeof(float));
 	if (cuda_ret != cudaSuccess) FATAL("Unable to allocate device memory");
	cuda_ret = cudaMalloc(&dev_output_img, img_size_total * sizeof(float));
 	if (cuda_ret != cudaSuccess) FATAL("Unable to allocate device memory");

	//Copy data from OpenCV input image to device memory
	cuda_ret = cudaMemcpy(dev_input_img, in_img.ptr(), img_size_total * sizeof(float), cudaMemcpyHostToDevice);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to device memory");

	//Specify a reasonable block size
	const dim3 dim_block(BLOCK_SIZE, BLOCK_SIZE);

	//Calculate grid size to cover the whole image
	const dim3 dim_grid(((in_img.cols - 1) / BLOCK_SIZE) + 1, ((in_img.rows - 1) / BLOCK_SIZE) + 1);

	convert_to_luv_gpu_kernel<<<dim_grid, dim_block>>>(dev_input_img, dev_output_img, n, useRGB);

	//Synchronize to check for any kernel launch errors
	cuda_ret = cudaDeviceSynchronize();
 	if (cuda_ret != cudaSuccess) FATAL("Unable to launch kernel");

	//Copy back data from destination device meory to OpenCV output image
	cuda_ret = cudaMemcpy(res_img.ptr(), dev_output_img, img_size_total * sizeof(float), cudaMemcpyDeviceToHost);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to copy from device memory");

	//Free the device memory
	cuda_ret = cudaFree(dev_input_img);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to free device memory");
	cuda_ret = cudaFree(dev_output_img);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to free device memory");

	return;
}

void img_process::rgb2luv(cv::Mat& in_img, cv::Mat& out_img)
{
	CV_Assert( in_img.type() == CV_8UC3);
	float nrm =  1.0f/255;
	rgb2luv_setup(nrm);
	unsigned char *B = in_img.ptr<unsigned char>(0), *G = in_img.ptr<unsigned char>(0) + 1, *R = in_img.ptr<unsigned char>(0) + 2;
	cv::Mat res_img(in_img.rows, in_img.cols, CV_32FC3);
	out_img = res_img;
	int n = in_img.rows * in_img.cols;
	/// xma opencv order of each channel:
	/// get l,u,v pointer and r g b pointer
	float *L=out_img.ptr<float>(0), *U=out_img.ptr<float>(0) + 1, *V=out_img.ptr<float>(0) + 2;
	for( int i=0; i<n; i++ )
	{
		float r, g, b, x, y, z, l;
		r=static_cast<float>(*R); g=static_cast<float>(*G); b=static_cast<float>(*B);
		R += 3;
		G += 3;
		B += 3;
		x = mr[0]*r + mg[0]*g + mb[0]*b;
		y = mr[1]*r + mg[1]*g + mb[1]*b;
		z = mr[2]*r + mg[2]*g + mb[2]*b;
		l = lTable[static_cast<int>((y*1024))];
		*(L) = l; z = 1/(x + 15*y + 3*z + (float)1e-35);
		*(U) = l * (13*4*x*z - 13*un) - minu;
		*(V) = l * (13*9*y*z - 13*vn) - minv;
		L += 3;
		U += 3;
		V += 3;
	}
	return;
}

void img_process::rgb2luv_gpu(cv::Mat& in_img, cv::Mat& out_img)
{
	CV_Assert(in_img.type() == CV_32FC3);
	float nrm =  1.0f/255;
	rgb2luv_setup_gpu(nrm);

	cv::Mat res_img(in_img.rows, in_img.cols, CV_32FC3);
	float *dev_input_img, *dev_output_img;
	unsigned int img_size_total = in_img.step * in_img.rows;
	cudaError_t cuda_ret;

	//Allocate device memory
	cuda_ret = cudaMalloc(&dev_input_img, img_size_total * sizeof(float));
 	if (cuda_ret != cudaSuccess) FATAL("Unable to allocate device memory");
	cuda_ret = cudaMalloc(&dev_output_img, img_size_total * sizeof(float));
 	if (cuda_ret != cudaSuccess) FATAL("Unable to allocate device memory");

	//Copy data from OpenCV input image to device memory
	cuda_ret = cudaMemcpy(dev_input_img, in_img.ptr(), img_size_total * sizeof(float), cudaMemcpyHostToDevice);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to device memory");

	//Specify a reasonable block size
	const dim3 dim_block(BLOCK_SIZE, BLOCK_SIZE);

	//Calculate grid size to cover the whole image
	const dim3 dim_grid(((in_img.cols - 1) / BLOCK_SIZE) + 1, ((in_img.rows - 1) / BLOCK_SIZE) + 1);

	convert_to_luv_gpu_kernel<<<dim_grid, dim_block>>>(dev_input_img, dev_output_img, n, false);

	//Synchronize to check for any kernel launch errors
	cuda_ret = cudaDeviceSynchronize();
 	if (cuda_ret != cudaSuccess) FATAL("Unable to launch kernel");

	//Copy back data from destination device meory to OpenCV output image
	cuda_ret = cudaMemcpy(res_img.ptr(), dev_output_img, img_size_total * sizeof(float), cudaMemcpyDeviceToHost);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to copy from device memory");

	//Free the device memory
	cuda_ret = cudaFree(dev_input_img);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to free device memory");
	cuda_ret = cudaFree(dev_output_img);
 	if (cuda_ret != cudaSuccess) FATAL("Unable to free device memory");

	return;
}

void img_process::rgb2luv_setup(float nrm)
{
	// set constants for conversion
	const float y0 = ((6.0f/29)*(6.0f/29)*(6.0f/29));
	const float a  = ((29.0f/3)*(29.0f/3)*(29.0f/3));
	un = 0.197833f; vn = 0.468331f;
	mr[0]= 0.430574f*nrm; mr[1]= 0.222015f*nrm; mr[2]= 0.020183f*nrm;
	mg[0]= 0.341550f*nrm; mg[1]= 0.706655f*nrm; mg[2]= 0.129553f*nrm;
	mb[0]= 0.178325f*nrm; mb[1]= 0.071330f*nrm; mb[2]= 0.939180f*nrm;
	float maxi= 1.0f/270; minu=-88.0f*maxi; minv=-134.0f*maxi;
	// build (padded) lookup table for y->l conversion assuming y in [0,1]
	float y, l;
	for(int i=0; i<1025; i++)
	{
		y =  (i/1024.0);
		l = y>y0 ? 116*pow((double)y,1.0/3.0)-16 : y*a;
		lTable[i] = l*maxi;
	}
	for(int i=1025; i<1064; i++)
		lTable[i]=lTable[i-1];
	return;
}

void img_process::rgb2luv_setup_gpu(float nrm)
{
	// set constants for conversion
	const float y0 = ((6.0f / 29) * (6.0f / 29) * (6.0f / 29));
	const float a  = ((29.0f / 3) * (29.0f / 3) * (29.0f / 3));

	mr[0] = 0.430574f * nrm; mr[1] = 0.222015f * nrm; mr[2] = 0.020183f * nrm;
	mg[0] = 0.341550f * nrm; mg[1] = 0.706655f * nrm; mg[2] = 0.129553f * nrm;
	mb[0] = 0.178325f * nrm; mb[1] = 0.071330f * nrm; mb[2] = 0.939180f * nrm;

	cudaError_t cuda_ret;
	cuda_ret = cudaMemcpyToSymbol(mr_const, mr, sizeof(float) * 3, 0);
	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to constant memory");
	cuda_ret = cudaMemcpyToSymbol(mg_const, mg, sizeof(float) * 3, 0);
	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to constant memory");
	cuda_ret = cudaMemcpyToSymbol(mb_const, mb, sizeof(float) * 3, 0);
	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to constant memory");

	// build (padded) lookup table for y->l conversion assuming y in [0,1]
	float maxi = 1.0f / 270;
	float y, l;
	for (int i = 0; i < 1025; i++)
	{
		y =  (i / 1024.0);
		l = y > y0 ? 116 * pow((double)y, 1.0 / 3.0) - 16 : y * a;
		lTable[i] = l * maxi;
	}

	for(int i = 1025; i < 1064; i++)
		lTable[i] = lTable[i - 1];

	cuda_ret = cudaMemcpyToSymbol(lTable_const, lTable, sizeof(float) * 1064, 0);
	if (cuda_ret != cudaSuccess) FATAL("Unable to copy to constant memory");

	return;
}


void img_process::resampleCoef( int ha, int hb, int &n, int *&yas,
								int *&ybs, float *&wts, int bd[2], int pad)
{
    /// xma input:  ha, hb,
    /// xma output: n,  yas, ybs, wts, bd,0
    /// xma s is the scale factor
    const float s = static_cast<float>(hb)/static_cast<float>(ha), sInv = 1/s; float wt, wt0=static_cast<float>(1e-3)*s;
	//cout << "s = " << s << " sInv = " << sInv << " wt0 = " << wt0 << " pad = " << pad << endl;
    /// determine either downsample or upsample for resampling
    bool ds=ha>hb;
    int nMax; bd[0]=bd[1]=0;
    if(ds)
    {
        n=0;
        nMax=ha+(pad>2 ? pad : 2)*hb;
    }
    else
    {
        n=nMax=hb;
    }
	//cout << "nMax = " << nMax << endl;
    // initialize memory
    wts = new float[nMax];
    yas = new int[nMax];
    ybs = new int[nMax];
    if( ds )
	{
        for( int yb=0; yb<hb; yb++ )
        {
            // create coefficients for downsampling

            float ya0f=yb*sInv, ya1f=ya0f+sInv, W=0;
            int ya0=int(ceil(ya0f)), ya1=int(ya1f), n1=0;
			//cout << "ya0f = " << ya0f << ", ya1f = " << ya1f << ", ya0 = << " << ya0 << ", ya1 = " << ya1 << endl;
            for( int ya=ya0-1; ya<ya1+1; ya++ )
            {
                wt=s;
                if(ya==ya0-1)
                    wt=(ya0-ya0f)*s;
                else if(ya==ya1)
                    wt=(ya1f-ya1)*s;
				/// only when the weight is larger than 10-3, consider it as a valid weight (at the edge).
				if(wt>wt0 && ya>=0)
                {
                    ybs[n]=yb;
                    yas[n]=ya;
                    wts[n]=wt;
                    n++;
                    n1++;
                    W+=wt;
                }
            }
            if(W>1) for( int i=0; i<n1; i++ ) wts[n-n1+i]/=W;
            if(n1>bd[0]) bd[0]=n1;
            while( n1<pad )
            {
                ybs[n]=yb; yas[n]=yas[n-1]; wts[n]=0; n++; n1++;
            }
        }
	}
	else
	{
		for( int yb=0; yb<hb; yb++ )
		{
			// create coefficients for upsampling
			float yaf = (float(.5)+yb)*sInv-float(.5); int ya=(int) floor(yaf);
			wt=1; if(ya>=0 && ya<ha-1) wt=1-(yaf-ya);
			if(ya<0) { ya=0; bd[0]++; }
			if(ya>=ha-1)
			{
				ya=ha-1;
				bd[1]++;
			}
			ybs[yb]=yb;
			yas[yb]=ya;
			wts[yb]=wt;
		}
	}
	/*
	cout << left << setw(15) << "wts " << left << setw(15) <<  "yas " << left << setw(15) << "ybs" << endl;
	for(int idx = 0; idx < nMax; ++idx)
		cout << left << setw(15) << wts[idx] << left << setw(15) << yas[idx] << left << setw(15) << ybs[idx] << endl;
	cout << "n = " << n << " bd[0] = " << bd[0] << " bd[1] = " << bd[1] << endl << endl << endl << endl;
	*/
}

/// bilinear interpolation methods to resize image (opencv mat version, no SSE, interleaved to interleaved memory)
void img_process::imResample(cv::Mat& in_img, cv::Mat& out_img, int dheight, int dwidth, float r )
{
	cv::Mat img_resample = cv::Mat::zeros(dheight, dwidth, in_img.type());
	int d = 1;
	if(in_img.type() == CV_32FC1)
		d = 1;
	else if(in_img.type() == CV_32FC2)
		d = 2;
	else if(in_img.type() == CV_32FC3)
		d = 3;
	else
		CV_Assert(0);
	int org_ht = in_img.rows, org_wd = in_img.cols, dst_ht = dheight, dst_wd = dwidth;
	out_img = img_resample;
	int hn, wn, x, /*x1,*/ y, z, xa, /*xb,*/ ya, yb, y1 /* xma added to convert from col major to row major*/;
	float *A0, *A1, *A2, *A3, *B0, wt, wt1;
	/// xma prepare 128-bit aligned array C of org height+4 and set boundary values to 0
	float *C = new float[org_wd+4]; for(x=org_wd; x<org_wd+4; x++) C[x]=0;
	//bool sse = (typeid(T)==typeid(float)) && !(size_t(A)&15) && !(size_t(B)&15);
	// sse = false
	// get coefficients for resampling along w and h
	int *xas, *xbs, *yas, *ybs; float *xwts, *ywts; int xbd[2], ybd[2];
	/// xma resampleCoef input is only org_wd, org_wd, output wn, xas, xbs, xwts, xbd,0
	/// vertical coef
	resampleCoef( org_wd, dst_wd, wn, xas, xbs, xwts, xbd, 4 );
	/// horizontal coef
	resampleCoef( org_ht, dst_ht, hn, yas, ybs, ywts, ybd, 0 );
	if( org_ht==2*dst_ht ) r/=2;
	if( org_ht==3*dst_ht ) r/=3;
	if( org_ht==4*dst_ht ) r/=4;
	r/=float(1+1e-6);
	for( x=0; x<wn; x++ )
	{
		xwts[x] *= r;
		//cout << "xwts[" << x << "] = " << xwts[x] << endl;
	}
	// resample each color channel separately)
	for( z=0; z<d; z++ )
	{
		float *A = in_img.ptr<float>(0) + z;
		float *B = img_resample.ptr<float>(0) + z;
		for( y=0; y<dst_ht; y++)
		{
			if(y==0) y1=0;
			ya=yas[y1];
			yb=ybs[y1];
			wt=ywts[y1];
			wt1=1-wt;
			x=0;
			/// xma four points in org img for bilinear interpolation
			/// xma z*org_ht*org_wd is color channel offset,
			A0=A+ya*org_wd*d; // point to current row based on ya, (memory channel is interleaved, so each row takes org_wd*d spaces)
			/// bilinear interpolation, each direction, need to use 4 points to estimate the final value
			A1=A0+org_wd*d ;
			A2=A1+org_wd*d ;
			A3=A2+org_wd*d ;
			/// compute the pointer to the resampled image, current scale(for interleaved color channel)
			B0=B+yb*dst_wd*d;
			//cout << "ya = " << ya  << " yb = " << yb  << " wt = " << wt  << " wt1 = " << wt1 << endl;
			//cout << "A0 = " << *A0 << " A1 = " << *A1 << " A2 = " << *A2 << " A3  = " << *A3 << endl;
			// resample along y direction
			if( org_ht==2*dst_ht )
			{
				//cout << "testing scale height by 1/2." << endl;
				for(; x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d];
				}
				y1 += 2;
		    }
			else if( org_ht==3*dst_ht )
			{
				//cout << "testing scale height by 1/3." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d] + A2[x*d];
				}
				y1+=3;
			}
			else if( org_ht==4*dst_ht )
			{
				//cout << "testing scale height by 1/4." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d] + A2[x*d] + A3[x*d];
				}
				y1+=4;
			}
			else if( org_ht > dst_ht )
			{
				//cout << "testing scale height by any other number." << endl;
				int m=1;
				while( y1+m<hn && yb==ybs[y1+m] ) m++;
				//cout << "hn = " << hn << " y1 = " << y1 << " m = " << m << endl;
				if(m==1)
				{
					for(;x < org_wd; ++x)
					{
						C[x] = A0[x*d] * ywts[y1];
					}

				}
				if(m==2)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1];
					}
				}
				if(m==3)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1] + A2[x*d] * ywts[y1+2];
					}
				}
				if(m>=4)
				{
					for(; x < org_wd;++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1] + A2[x*d] * ywts[y1+2] + A3[x*d] * ywts[y1+3];
					}
				}

				for( int y0=4; y0<m; y0++ )
				{
					A1=A0+y0*org_wd*d; wt1=ywts[y1+y0]; x=0;
					for(; x < org_wd; ++x)
					{
						C[x] = C[x] + A1[x*d]*wt1;
					}
				}
				y1+=m;
			}
			else
			{
				//cout << "testing scale height up " << endl;
				bool yBd = y < ybd[0] || y>=dst_ht-ybd[1]; y1++;
				//cout << "yBd = " << yBd << " ybd[0] = " << ybd[0] << " ybd[1] = " << ybd[1] << " y1 = " << y1 << endl;
				if(yBd)
					for(int tempx = 0; tempx < org_wd; ++tempx)
						C[tempx] = A0[tempx*d];
				else
				{
					for(int tempx = 0; tempx < org_wd; ++tempx)
					{
						C[tempx] = A0[tempx*d]*wt + A1[tempx*d]*wt1;
					}
				}
			}
			// resample along x direction (B -> C)
			if( org_wd==dst_wd*2 )
			{
				//cout << "testing scale width by 1/2." << endl;
				float r2 = r/2;
				for(x=0 ; x < dst_wd; x++ )
					B0[x*d]=(C[2*x]+C[2*x+1])*r2;
			}
			else if( org_wd==dst_wd*3 )
			{
				//cout << "testing scale width by 1/3." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x*d]=(C[3*x]+C[3*x+1]+C[3*x+2])*(r/3);
			}
			else if( org_wd==dst_wd*4 )
			{
				//cout << "testing scale width by 1/4." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x*d]=(C[4*x]+C[4*x+1]+C[4*x+2]+C[4*x+3])*(r/4);
			}
			else if( org_wd>dst_wd )
			{
				//cout << "testing scale width by any number." << endl;
				//cout << "xbd[0] = " << xbd[0] << endl;
				x=0;
				//#define U(o) C[xa+o]*xwts[x*4+o]
				if(xbd[0]==2)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x*d] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1];//        U(0)+U(1);
					}
				if(xbd[0]==3)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x*d] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2];//U(0)+U(1)+U(2);
					}
				if(xbd[0]==4)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x*d] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2] + C[xa+3]*xwts[x*4+3];//U(0)+U(1)+U(2)+U(3);
					}
				if(xbd[0]>4)
					for(; x<wn; x++)
					{
						B0[xbs[x]*d] += C[xas[x]] * xwts[x];
					}
			}
			else
			{
				//cout << "testing scale width up!" << endl;
				for(x=0; x<xbd[0]; x++)
					B0[x*d] = C[xas[x]]*xwts[x];
				for(; x<dst_wd-xbd[1]; x++)
					B0[x*d] = C[xas[x]]*xwts[x]+C[xas[x]+1]*(r-xwts[x]);
				for(; x<dst_wd; x++)
					B0[x*d] = C[xas[x]]*xwts[x];
			}
		}
	}
	delete[] C;
	delete[] xas;
	delete[] xbs;
	delete[] xwts;
	delete[] yas;
	delete[] ybs;
	delete[] ywts;
	return;
}

/// bilinear interpolation methods to resize image (array version, no SSE)
/// note that for the input array, the different color channels are interleaved, but for the output array, the memory channels are separated
void img_process::imResample_array_int2lin(float* in_img, float* out_img, int d, int org_ht, int org_wd, int dst_ht, int dst_wd, float r )
{

	int hn, wn, x, /*x1,*/ y, z, xa, /*xb,*/ ya, yb, y1 /* xma added to convert from col major to row major*/;
	float *A0, *A1, *A2, *A3, *B0, wt, wt1;
	/// xma prepare 128-bit aligned array C of org height+4 and set boundary values to 0
	float *C = new float[org_wd+4]; for(x=org_wd; x<org_wd+4; x++) C[x]=0;
	//bool sse = (typeid(T)==typeid(float)) && !(size_t(A)&15) && !(size_t(B)&15);
	// sse = false
	// get coefficients for resampling along w and h
	int *xas, *xbs, *yas, *ybs; float *xwts, *ywts; int xbd[2], ybd[2];
	/// xma resampleCoef input is only org_wd, org_wd, output wn, xas, xbs, xwts, xbd,0
	/// vertical coef
	resampleCoef( org_wd, dst_wd, wn, xas, xbs, xwts, xbd, 4 );
	/// horizontal coef
	resampleCoef( org_ht, dst_ht, hn, yas, ybs, ywts, ybd, 0 );
	if( org_ht==2*dst_ht ) r/=2;
	if( org_ht==3*dst_ht ) r/=3;
	if( org_ht==4*dst_ht ) r/=4;
	r/=float(1+1e-6);
	for( x=0; x<wn; x++ )
	{
		xwts[x] *= r;
		//cout << "xwts[" << x << "] = " << xwts[x] << endl;
	}
	/// check if only re-assemble the pixel values:
	if(org_ht == dst_ht && org_wd == dst_wd)
	{
		for(int chn = 0; chn < d; ++chn)
			for(int idx = chn; idx < org_ht*org_wd*d; idx += d)
			{
				out_img[0] = in_img[idx];
				out_img++;
			}
		return;
	}
	memset(out_img, 0, sizeof(float)*dst_ht*dst_wd*d);
	// resample each color channel separately)
	for( z=0; z<d; z++ )
	{
		float *A = in_img + z;
		float *B = out_img + z * dst_ht * dst_wd;
		//cout << "z = " << z << endl;
		for( y=0; y<dst_ht; y++)
		{
			if(y==0) y1=0;
			ya=yas[y1];
			yb=ybs[y1];
			wt=ywts[y1];
			wt1=1-wt;
			x=0;
			/// xma four points in org img for bilinear interpolation
			/// xma z*org_ht*org_wd is color channel offset,
			A0=A+ya*org_wd*d; // point to current row based on ya, (memory channel is interleaved, so each row takes org_wd*d spaces)
			/// bilinear interpolation, each direction, need to use 4 points to estimate the final value
			A1=A0+org_wd*d ;
			A2=A1+org_wd*d ;
			A3=A2+org_wd*d ;
			/// compute the pointer to the resampled image, current scale(for interleaved color channel)
			B0=B+yb*dst_wd;
			//cout << "ya = " << ya  << " yb = " << yb  << " wt = " << wt  << " wt1 = " << wt1 << endl;
			//cout << "A0 = " << *A0 << " A1 = " << *A1 << " A2 = " << *A2 << " A3  = " << *A3 << endl;
			// resample along y direction
			if( org_ht==2*dst_ht )
			{
				//cout << "testing scale height by 1/2." << endl;
				for(; x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d];
				}
				y1 += 2;
		    }
			else if( org_ht==3*dst_ht )
			{
				//cout << "testing scale height by 1/3." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d] + A2[x*d];
				}
				y1+=3;
			}
			else if( org_ht==4*dst_ht )
			{
				//cout << "testing scale height by 1/4." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x*d] + A1[x*d] + A2[x*d] + A3[x*d];
				}
				y1+=4;
			}
			else if( org_ht > dst_ht )
			{
				//cout << "testing scale height by any other number." << endl;
				int m=1;
				while( y1+m<hn && yb==ybs[y1+m] ) m++;
				//cout << "hn = " << hn << " y1 = " << y1 << " m = " << m << endl;
				if(m==1)
				{
					for(;x < org_wd; ++x)
					{
						C[x] = A0[x*d] * ywts[y1];
					}

				}
				if(m==2)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1];
					}
				}
				if(m==3)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1] + A2[x*d] * ywts[y1+2];
					}
				}
				if(m>=4)
				{
					for(; x < org_wd;++x)
					{
						C[x] =  A0[x*d] * ywts[y1] + A1[x*d] * ywts[y1+1] + A2[x*d] * ywts[y1+2] + A3[x*d] * ywts[y1+3];
					}
				}

				for( int y0=4; y0<m; y0++ )
				{
					A1=A0+y0*org_wd*d; wt1=ywts[y1+y0]; x=0;
					for(; x < org_wd; ++x)
					{
						C[x] = C[x] + A1[x*d]*wt1;
					}
				}
				y1+=m;
			}
			else
			{
				//cout << "testing scale height up " << endl;
				bool yBd = y < ybd[0] || y>=dst_ht-ybd[1]; y1++;
				//cout << "yBd = " << yBd << " ybd[0] = " << ybd[0] << " ybd[1] = " << ybd[1] << " y1 = " << y1 << endl;
				if(yBd)
					for(int tempx = 0; tempx < org_wd; ++tempx)
						C[tempx] = A0[tempx*d];
				else
				{
					for(int tempx = 0; tempx < org_wd; ++tempx)
					{
						C[tempx] = A0[tempx*d]*wt + A1[tempx*d]*wt1;
					}
				}
			}
			// resample along x direction (B -> C)
			if( org_wd==dst_wd*2 )
			{
				//cout << "testing scale width by 1/2." << endl;
				float r2 = r/2;
				for(x=0 ; x < dst_wd; x++ )
					B0[x]=(C[2*x]+C[2*x+1])*r2;
			}
			else if( org_wd==dst_wd*3 )
			{
				//cout << "testing scale width by 1/3." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x]=(C[3*x]+C[3*x+1]+C[3*x+2])*(r/3);
			}
			else if( org_wd==dst_wd*4 )
			{
				//cout << "testing scale width by 1/4." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x]=(C[4*x]+C[4*x+1]+C[4*x+2]+C[4*x+3])*(r/4);
			}
			else if( org_wd>dst_wd )
			{
				//cout << "testing scale width by any number." << endl;
				//cout << "xbd[0] = " << xbd[0] << endl;
				x=0;
				//#define U(o) C[xa+o]*xwts[x*4+o]
				if(xbd[0]==2)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1];//        U(0)+U(1);
					}
				if(xbd[0]==3)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2];//U(0)+U(1)+U(2);
					}
				if(xbd[0]==4)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2] + C[xa+3]*xwts[x*4+3];//U(0)+U(1)+U(2)+U(3);
					}
				if(xbd[0]>4)
					for(; x<wn; x++)
					{
						B0[xbs[x]] += C[xas[x]] * xwts[x];
					}
			}
			else
			{
				//cout << "testing scale width up!" << endl;
				for(x=0; x<xbd[0]; x++)
					B0[x] = C[xas[x]]*xwts[x];
				for(; x<dst_wd-xbd[1]; x++)
					B0[x] = C[xas[x]]*xwts[x]+C[xas[x]+1]*(r-xwts[x]);
				for(; x<dst_wd; x++)
					B0[x] = C[xas[x]]*xwts[x];
			}
		}
	}
	delete[] C;
	delete[] xas;
	delete[] xbs;
	delete[] xwts;
	delete[] yas;
	delete[] ybs;
	delete[] ywts;
	return;
}

/// bilinear interpolation methods to resize image (array version, no SSE)
/// note that for the input array, the different color channels are separated, linearly sotred in memory,same for the output array
void img_process::imResample_array_lin2lin(float* in_img, float* out_img, int d, int org_ht, int org_wd, int dst_ht, int dst_wd, float r )
{

	int hn, wn, x, /*x1,*/ y, z, xa, /*xb,*/ ya, yb, y1 /* xma added to convert from col major to row major*/;
	float *A0, *A1, *A2, *A3, *B0, wt, wt1;
	float *C = new float[org_wd+4]; for(x=org_wd; x<org_wd+4; x++) C[x]=0;
	//bool sse = (typeid(T)==typeid(float)) && !(size_t(A)&15) && !(size_t(B)&15);
	// sse = false
	// get coefficients for resampling along w and h
	int *xas, *xbs, *yas, *ybs; float *xwts, *ywts; int xbd[2], ybd[2];
	/// xma resampleCoef input is only org_wd, org_wd, output wn, xas, xbs, xwts, xbd,0
	/// vertical coef
	resampleCoef( org_wd, dst_wd, wn, xas, xbs, xwts, xbd, 4 );
	/// horizontal coef
	resampleCoef( org_ht, dst_ht, hn, yas, ybs, ywts, ybd, 0 );
	//cout << "org_wd = " << org_wd << " dst_wd = " << dst_wd << " wn = " << wn << " ybd[0] = " << ybd[0] << " ybd[1] = " << ybd[1] << endl;
	//cout << "org_ht = " << org_ht << " dst_ht = " << dst_ht << " hn = " << hn << " xbd[0] = " << xbd[0] << " xbd[1] = " << xbd[1] << endl;
	if( org_ht==2*dst_ht ) r/=2;
	if( org_ht==3*dst_ht ) r/=3;
	if( org_ht==4*dst_ht ) r/=4;
	r/=float(1+1e-6);
	for( x=0; x<wn; x++ )
	{
		xwts[x] *= r;
		//cout << "xwts[" << x << "] = " << xwts[x] << endl;
	}
	//cout << "r = " << r << endl;
	memset(out_img, 0, sizeof(float)*dst_ht*dst_wd*d);
	// resample each color channel separately)
	for( z=0; z<d; z++ )
	{
		float *A = in_img  + z * org_ht * org_wd;
		float *B = out_img + z * dst_ht * dst_wd;
		//cout << "z = " << z << endl;
		for( y=0; y<dst_ht; y++)
		{
			if(y==0) y1=0;
			ya=yas[y1];
			yb=ybs[y1];
			wt=ywts[y1];
			wt1=1-wt;
			x=0;
			/// xma four points in org img for bilinear interpolation
			/// xma z*org_ht*org_wd is color channel offset,
			A0=A+ya*org_wd; // point to current row based on ya, (memory channel is linear, so each row is org_wd )
			/// bilinear interpolation, each direction, need to use 4 points to estimate the final value
			A1=A0+org_wd ;
			A2=A1+org_wd ;
			A3=A2+org_wd ;
			/// compute the pointer to the resampled image, current scale(for interleaved color channel)
			B0=B+yb*dst_wd;
			//cout << "ya = " << ya  << " yb = " << yb  << " wt = " << wt  << " wt1 = " << wt1 << endl;
			//cout << "A0 = " << *A0 << " A1 = " << *A1 << " A2 = " << *A2 << " A3  = " << *A3 << endl;
			// resample along y direction
			if( org_ht==2*dst_ht )
			{
				//cout << "testing scale height by 1/2." << endl;
				for(; x < org_wd; ++x)
				{
					C[x] = A0[x] + A1[x];
				}
				y1 += 2;
		    }
			else if( org_ht==3*dst_ht )
			{
				//cout << "testing scale height by 1/3." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x] + A1[x] + A2[x];
				}
				y1+=3;
			}
			else if( org_ht==4*dst_ht )
			{
				//cout << "testing scale height by 1/4." << endl;
				for(;x < org_wd; ++x)
				{
					C[x] = A0[x] + A1[x] + A2[x] + A3[x];
				}
				y1+=4;
			}
			else if( org_ht > dst_ht )
			{
				//cout << "testing scale height by any other number." << endl;
				int m=1;
				while( y1+m<hn && yb==ybs[y1+m] ) m++;
				//cout << "hn = " << hn << " y1 = " << y1 << " m = " << m << endl;
				if(m==1)
				{
					for(;x < org_wd; ++x)
					{
						C[x] = A0[x] * ywts[y1];
					}

				}
				if(m==2)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x] * ywts[y1] + A1[x] * ywts[y1+1];
					}
				}
				if(m==3)
				{
					for(;x < org_wd; ++x)
					{
						C[x] =  A0[x] * ywts[y1] + A1[x] * ywts[y1+1] + A2[x] * ywts[y1+2];
					}
				}
				if(m>=4)
				{
					for(; x < org_wd;++x)
					{
						C[x] =  A0[x] * ywts[y1] + A1[x] * ywts[y1+1] + A2[x] * ywts[y1+2] + A3[x] * ywts[y1+3];
					}
				}

				for( int y0=4; y0<m; y0++ )
				{
					A1=A0+y0*org_wd; wt1=ywts[y1+y0]; x=0;
					for(; x < org_wd; ++x)
					{
						C[x] = C[x] + A1[x]*wt1;
					}
				}
				y1+=m;
			}
			else
			{
				//cout << "testing scale height up " << endl;
				bool yBd = y < ybd[0] || y>=dst_ht-ybd[1]; y1++;
				//cout << "yBd = " << yBd << " ybd[0] = " << ybd[0] << " ybd[1] = " << ybd[1] << " y1 = " << y1 << endl;
				if(yBd)
					for(int tempx = 0; tempx < org_wd; ++tempx)
						C[tempx] = A0[tempx];
				else
				{
					for(int tempx = 0; tempx < org_wd; ++tempx)
					{
						C[tempx] = A0[tempx]*wt + A1[tempx]*wt1;
					}
				}
			}
			// resample along x direction (B -> C)
			if( org_wd==dst_wd*2 )
			{
				//cout << "testing scale width by 1/2." << endl;
				float r2 = r/2;
				for(x=0 ; x < dst_wd; x++ )
					B0[x]=(C[2*x]+C[2*x+1])*r2;
			}
			else if( org_wd==dst_wd*3 )
			{
				//cout << "testing scale width by 1/3." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x]=(C[3*x]+C[3*x+1]+C[3*x+2])*(r/3);
			}
			else if( org_wd==dst_wd*4 )
			{
				//cout << "testing scale width by 1/4." << endl;
				for(x=0; x<dst_wd; x++)
					B0[x]=(C[4*x]+C[4*x+1]+C[4*x+2]+C[4*x+3])*(r/4);
			}
			else if( org_wd>dst_wd )
			{
				//cout << "testing scale width by any number." << endl;
				//cout << "xbd[0] = " << xbd[0] << endl;
				x=0;
				//#define U(o) C[xa+o]*xwts[x*4+o]
				if(xbd[0]==2)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1];//        U(0)+U(1);
					}
				if(xbd[0]==3)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2];//U(0)+U(1)+U(2);
					}
				if(xbd[0]==4)
					for(; x<dst_wd; x++)
					{
						xa=xas[x*4];
						B0[x] = C[xa]*xwts[x*4] + C[xa+1]*xwts[x*4+1] + C[xa+2]*xwts[x*4+2] + C[xa+3]*xwts[x*4+3];//U(0)+U(1)+U(2)+U(3);
					}
				if(xbd[0]>4)
					for(; x<wn; x++)
					{
						B0[xbs[x]] += C[xas[x]] * xwts[x];
					}
			}
			else
			{
				//cout << "testing scale width up!" << endl;
				for(x=0; x<xbd[0]; x++)
					B0[x] = C[xas[x]]*xwts[x];
				for(; x<dst_wd-xbd[1]; x++)
					B0[x] = C[xas[x]]*xwts[x]+C[xas[x]+1]*(r-xwts[x]);
				for(; x<dst_wd; x++)
					B0[x] = C[xas[x]]*xwts[x];
			}
		}
	}
	delete[] C;
	delete[] xas;
	delete[] xbs;
	delete[] xwts;
	delete[] yas;
	delete[] ybs;
	delete[] ywts;
	return;
}

void img_process::ConvTri1(float* I, float* O, int ht, int wd, int dim, float p, int s)
{
    const float nrm = 1.0f/((p+2)*(p+2));
	float *It, *Im, *Ib, *T= new float[wd];
	/// perform convTri dimension by dimension
	for( int d0=0; d0<dim; d0++ )
	{
		for(int y=s/2; y<ht; y+= s )  /// this is equivalent to i = 0 to ht
		{
			/// point It to the current dim and row
			It= Im = Ib = I+ y*wd+d0*ht*wd;
			if(y>0) /// not the first row, let It point to previous row
				It-=wd;
			if(y < ht-1) /// not the last row, let Ib point to next row
				Ib+=wd;
			for(int x=0; x< wd; ++x )
				T[x]=nrm*(It[x]+p*Im[x]+Ib[x]);
			ConvTri1X(T,O,wd,p,s);
			O += wd/s; /// point to next row
		}
	}
}

void img_process::ConvTri1X(float* I, float* O, int wd, float p, int s)
{
	int j = 0;
	O[j]=(1+p)*I[j]+I[j+1]; ++j;
	for(; j < wd - 1; ++j )
		O[j]=I[j-1]+p*I[j]+I[j+1];
	O[j]=I[j-1]+(1+p)*I[j];
}




/// copy the opencv mat files to array with interleaved color channels
void img_process::get_pix_all_scales_int(cv::Mat& img, const vector<cv::Size>& scales, float* pix_array)
{
#ifdef __OUTPUT_PIX__
	ofstream pix_out;
	pix_out.open("pix_out_int.txt",ios::out);
#endif
	for(vector<cv::Size>::const_iterator ii = scales.begin(); ii != scales.end(); ++ii)
	{
		cv::Mat img_small;
		unsigned height = static_cast<unsigned>(ii->height);
		unsigned width  = static_cast<unsigned>(ii->width);
		if(height == static_cast<unsigned>(img.rows) && width == static_cast<unsigned>(img.cols))
			img_small = img;
		else
			imResample(img, img_small, height,width, 1.0f);
		//cout << "Currently at scale " << ii - scales.begin() << ", height = " << img_small.rows << " width = " << img_small.cols  << ", number of channels = " << img_small.channels() << endl;
		float* mat_ptr = img_small.ptr<float>(0);
		unsigned array_sz = width*height*img_small.channels();
		memcpy(pix_array, mat_ptr, array_sz*sizeof(float));
#ifdef __OUTPUT_PIX__
		for(int i = 0; i < img_small.channels(); ++i)
			for(unsigned j = i; j < array_sz; j+= img_small.channels())
				pix_out << pix_array[j] << " ";
		pix_out << endl << endl;
#endif
		pix_array += array_sz;
	}
#ifdef __OUTPUT_PIX__
	pix_out.close();
#endif
	return;
}

/// copy opencv mat files to array with linear ordered color channels (each channel is stored separatly in memory)
/// this process is slightly slower than the interleaved memroy access (not able to use memcpy)
void img_process::get_pix_all_scales_lin(cv::Mat& img, const vector<cv::Size>& scales, float* pix_array)
{
#ifdef __OUTPUT_PIX__
	ofstream pix_out;
	pix_out.open("pix_out_lin.txt",ios::out);
#endif
	int arr_sz  = static_cast<unsigned>(scales[0].height) * static_cast<unsigned>(scales[0].width) * img.channels();
	float* img_small = new float[arr_sz];
	float* mat_ptr = img.ptr<float>(0);
	for(vector<cv::Size>::const_iterator ii = scales.begin(); ii != scales.end(); ++ii)
	{
		//cout << "Currently at scale # " << ii-scales.begin() << endl;
		int height = static_cast<int>(ii->height);
		int width  = static_cast<int>(ii->width);
		int array_sz = width*height*img.channels();
		imResample_array_int2lin(mat_ptr, img_small, img.channels(), img.rows, img.cols, height, width, 1.0f);
		memcpy(pix_array, img_small, array_sz*sizeof(float));

#ifdef __OUTPUT_PIX__
		for(int i = 0; i < array_sz; ++i)
		{
			pix_out << pix_array[i] << " ";
		}
		pix_out << endl << endl;
#endif
		pix_array += array_sz;
	}
#ifdef __OUTPUT_PIX__
	pix_out.close();
#endif
	delete[] img_small;
	return;
}

