#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layers/inq_conv_layer.hpp"
#include <cmath>

namespace caffe {

template <typename Dtype>
__global__ void TPCalc(const int n, Dtype *param, Dtype *mask,
                       const Dtype threshold) {
  CUDA_KERNEL_LOOP(i, n) {
    if (mask[i] == 1) {
      if (param[i] >= threshold) {
        param[i] = pow(2.0, floor(log(4.0 * param[i] / 3.0) / log(2.0)));
        mask[i] = 0;
      } else if (param[i] <= -threshold) {
        param[i] = -pow(2.0, floor(log(4.0 * (-param[i]) / 3.0) / log(2.0)));
        mask[i] = 0;
      }
    }
  }
}

template <typename Dtype>
void INQConvolutionLayer<Dtype>::Forward_gpu(
    const vector<Blob<Dtype> *> &bottom, const vector<Blob<Dtype> *> &top) {
  /* for two-power network */
  if (this->phase_ == TRAIN) {
    if (this->iter_ == 0) {
      // Make the corresponding weights & bias into two power form.
      if (this->blobs_.size() == 4 && (this->bias_term_)) {
        LOG(INFO) << "Shaping the weights in tp_conv...[gpu]";
        ShapeIntoTwoPower(this->blobs_[0].get(), this->blobs_[2].get(),
                          this->portions_, max_weight_quantum_exp_,
                          min_weight_quantum_exp_);
        LOG(INFO) << "Shaping the bias in tp_conv...[gpu]";
        ShapeIntoTwoPower(this->blobs_[1].get(), this->blobs_[3].get(),
                          this->portions_, max_bias_quantum_exp_,
                          min_bias_quantum_exp_);
        LOG(INFO) << "Shaping done in tp_conv...[gpu]";
      } else if (this->blobs_.size() == 2 && (!this->bias_term_)) {
        LOG(INFO) << "ERROR: No bias terms found... but continue...";
        std::cout << "Shaping ONLY the weights..." << std::endl;
        ShapeIntoTwoPower(this->blobs_[0].get(), this->blobs_[1].get(),
                          this->portions_, max_weight_quantum_exp_,
                          min_weight_quantum_exp_);
      }
    }
  }

  const Dtype *weight = this->blobs_[0]->mutable_gpu_data();
  const Dtype *bias = NULL;
  if (this->bias_term_) {
    bias = this->blobs_[1]->mutable_gpu_data();
  }

  // Forward calculation with (masked) weight and bias
  for (int i = 0; i < bottom.size(); ++i) {
    const Dtype *bottom_data = bottom[i]->gpu_data();
    Dtype *top_data = top[i]->mutable_gpu_data();
    for (int n = 0; n < this->num_; ++n) {
      this->forward_gpu_gemm(bottom_data + bottom[i]->offset(n), weight,
                             top_data + top[i]->offset(n));
      if (this->bias_term_) {
        this->forward_gpu_bias(top_data + top[i]->offset(n), bias);
      }
    }
  }
  // std::cout << "Forward done in tp_conv...[gpu]" << std::endl;
}

template <typename Dtype>
void INQConvolutionLayer<Dtype>::Backward_gpu(
    const vector<Blob<Dtype> *> &top, const vector<bool> &propagate_down,
    const vector<Blob<Dtype> *> &bottom) {
  // LOG(INFO) << "Starting Backward in tp_conv... [gpu]" ;
  const Dtype *weight = this->blobs_[0]->mutable_gpu_data();
  const Dtype *weightMask = this->blobs_[2]->gpu_data();
  Dtype *weight_diff = this->blobs_[0]->mutable_gpu_diff();
  for (int i = 0; i < top.size(); ++i) {
    const Dtype *top_diff = top[i]->gpu_diff();
    // Bias gradient, if necessary.
    if (this->bias_term_ && this->param_propagate_down_[1]) {
      const Dtype *biasMask = this->blobs_[3]->gpu_data();
      Dtype *bias_diff = this->blobs_[1]->mutable_gpu_diff();
      for (unsigned int k = 0; k < this->blobs_[1]->count(); ++k)
      {
          bias_diff[k] = bias_diff[k] * biasMask[k];
      }
      for (int n = 0; n < this->num_; ++n) {
        this->backward_gpu_bias(bias_diff, top_diff + top[i]->offset(n));
      }
      // LOG(INFO) << "bias_diff Backwarded in tp_conv... [gpu]";
    }
    if (this->param_propagate_down_[0] || propagate_down[i]) {
      const Dtype *bottom_data = bottom[i]->gpu_data();
      Dtype *bottom_diff = bottom[i]->mutable_gpu_diff();
      for (unsigned int k = 0; k < this->blobs_[0]->count(); ++k)
      {
          weight_diff[k] = weight_diff[k] * weightMask[k];
      }
      for (int n = 0; n < this->num_; ++n) {
        // gradient w.r.t. weight. Note that we will accumulate diffs.
        if (this->param_propagate_down_[0]) {
          this->weight_gpu_gemm(bottom_data + bottom[i]->offset(n),
                                top_diff + top[i]->offset(n), weight_diff);
        }
        // gradient w.r.t. bottom data, if necessary.
        if (propagate_down[i]) {
          this->backward_gpu_gemm(top_diff + top[i]->offset(n), weight,
                                  bottom_diff + bottom[i]->offset(n));
        }
      }
    }
  }
  // LOG(INFO) << "Backward finished in tp_conv... [gpu]";
}

template <typename Dtype>
void INQConvolutionLayer<Dtype>::ShapeIntoTwoPower(
    Blob<Dtype> *input_blob, Blob<Dtype> *mask_blob,
    const vector<float> &portions, const int &max_quantum_exp_,
    const int &min_quantum_exp_) {

  const float previous_portion = portions[0];
  const float current_portion = portions[1];
  Dtype *param = input_blob->mutable_gpu_data();
  Dtype *mask = mask_blob->mutable_gpu_data();

  int count = input_blob->count();
  int updated = 0;
  // floor(count * previous_portion);

  for (int i = 0; i < count; ++i) {
    if (mask[i] == 0) {
      updated++;
    }
  }

  int left = count - updated;
  int update = floor(count * current_portion) - updated;

  vector<Dtype> sort_param(left);

  int k = 0;
  if (update > 0) {
    for (int i = 0; i < count; ++i) {
      if (mask[i] == 1) {
        sort_param[k++] = fabs(param[i]);
      }
    }
    CHECK_EQ(k, left) << "Num of weights/bias that are not in 2 power form "
                         "does NOT match the portion!";
    sort(sort_param.begin(), sort_param.end());
    Dtype threshold = sort_param[left - update];

    TPCalc<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, param, mask, threshold);
    CUDA_POST_KERNEL_CHECK;

    LOG(INFO) << "Shaping finished in tp_conv... [gpu]";
    /*
    for (int i = 0; i < count; ++i){
        if (mask[i] == 1)
        {
            if (param[i] >= threshold)
            {
                param[i] = pow(2.0, floor(log(4.0 * param[i] / 3.0) / log(2.0))
    ); mask[i] = 0;
            }
            else if(param[i] <= -threshold)
            {
                param[i] = -pow(2.0, floor(log(4.0 * (-param[i]) / 3.0) /
    log(2.0)) ); mask[i] = 0;
            }
        }
    }
    */
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(INQConvolutionLayer);

} // namespace caffe