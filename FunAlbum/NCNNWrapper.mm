//
//  NCNNWrapper.m
//  FunAlbum
//
//  Created by Jinbin Xie on 11/9/18.
//  Copyright © 2018年 Jinbin Xie. All rights reserved.
//

#include <string>
#include <vector>
#include <time.h>
#include <algorithm>
#include <map>
#include <iostream>

// Put OpenCV include files at the top. Otherwise an error happens.
#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>

#import "NCNNWrapper.h"
#import "ncnn/ncnn/net.h"

using namespace std;
using namespace cv;

//////////////////// MTCNN PART BEG ////////////////////

struct Bbox
{
    float score;
    int x1;
    int y1;
    int x2;
    int y2;
    float area;
    float ppoint[10];
    float regreCoord[4];
};

class MTCNN {
public:
    MTCNN();
    MTCNN(const std::vector<std::string> param_files, const std::vector<std::string> bin_files);
    ~MTCNN();
    
    void SetMinFace(int minSize);
    void detect(ncnn::Mat& img_, std::vector<Bbox>& finalBbox);
    void detectMaxFace(ncnn::Mat& img_, std::vector<Bbox>& finalBbox);
    //  void detection(const cv::Mat& img, std::vector<cv::Rect>& rectangles);
    
private:
    void generateBbox(ncnn::Mat score, ncnn::Mat location, vector<Bbox>& boundingBox_, float scale);
    void nmsTwoBoxs(vector<Bbox> &boundingBox_, vector<Bbox> &previousBox_, const float overlap_threshold, string modelname = "Union");
    void nms(vector<Bbox> &boundingBox_, const float overlap_threshold, string modelname="Union");
    void refine(vector<Bbox> &vecBbox, const int &height, const int &width, bool square);
    void extractMaxFace(vector<Bbox> &boundingBox_);
    
    void PNet(float scale);
    void PNet();
    void RNet();
    void ONet();
    
    ncnn::Net Pnet, Rnet, Onet;
    ncnn::Mat img;
    
    const float nms_threshold[3] = {0.5f, 0.7f, 0.7f};
    const float mean_vals[3] = {127.5, 127.5, 127.5};
    const float norm_vals[3] = {0.0078125, 0.0078125, 0.0078125};
    const int MIN_DET_SIZE = 12;
    std::vector<Bbox> firstPreviousBbox_, secondPreviousBbox_, thirdPrevioussBbox_;
    std::vector<Bbox> firstBbox_, secondBbox_,thirdBbox_;
    int img_w, img_h;

private:
    const float threshold[3] = { 0.8f, 0.8f, 0.6f };
    int minsize = 40;
    const float pre_facetor = 0.709f;
};

bool cmpScore(Bbox lsh, Bbox rsh)
{
    if (lsh.score < rsh.score)
        return true;
    else
        return false;
}

bool cmpArea(Bbox lsh, Bbox rsh)
{
    if (lsh.area < rsh.area)
        return false;
    else
        return true;
}

MTCNN::MTCNN()
{
    NSString *det1BinPath = [[NSBundle mainBundle] pathForResource:@"det1" ofType:@"bin"];
    NSString *det2BinPath = [[NSBundle mainBundle] pathForResource:@"det2" ofType:@"bin"];
    NSString *det3BinPath = [[NSBundle mainBundle] pathForResource:@"det3" ofType:@"bin"];
    
    NSString *det1ParamPath = [[NSBundle mainBundle] pathForResource:@"det1" ofType:@"param"];
    NSString *det2ParamPath = [[NSBundle mainBundle] pathForResource:@"det2" ofType:@"param"];
    NSString *det3ParamPath = [[NSBundle mainBundle] pathForResource:@"det3" ofType:@"param"];
    
    Pnet.load_param([det1ParamPath UTF8String]);
    Pnet.load_model([det1BinPath UTF8String]);
    Rnet.load_param([det2ParamPath UTF8String]);
    Rnet.load_model([det2BinPath UTF8String]);
    Onet.load_param([det3ParamPath UTF8String]);
    Onet.load_model([det3BinPath UTF8String]);
    
    std::cout << "MTCNN loaded successfully" << std::endl;
}

MTCNN::MTCNN(const std::vector<std::string> param_files, const std::vector<std::string> bin_files)
{
    Pnet.load_param(param_files[0].data());
    Pnet.load_model(bin_files[0].data());
    Rnet.load_param(param_files[1].data());
    Rnet.load_model(bin_files[1].data());
    Onet.load_param(param_files[2].data());
    Onet.load_model(bin_files[2].data());
}

MTCNN::~MTCNN() {
    Pnet.clear();
    Rnet.clear();
    Onet.clear();
}

void MTCNN::SetMinFace(int minSize)
{
    minsize = minSize;
}

void MTCNN::generateBbox(ncnn::Mat score, ncnn::Mat location, std::vector<Bbox>& boundingBox_, float scale)
{
    const int stride = 2;
    const int cellsize = 12;
    //score p
    float *p = score.channel(1);//score.data + score.cstep;
    //float *plocal = location.data;
    Bbox bbox;
    float inv_scale = 1.0f/scale;
    for(int row=0;row<score.h;row++){
        for(int col=0;col<score.w;col++){
            if(*p>threshold[0]){
                bbox.score = *p;
                bbox.x1 = round((stride*col+1)*inv_scale);
                bbox.y1 = round((stride*row+1)*inv_scale);
                bbox.x2 = round((stride*col+1+cellsize)*inv_scale);
                bbox.y2 = round((stride*row+1+cellsize)*inv_scale);
                bbox.area = (bbox.x2 - bbox.x1) * (bbox.y2 - bbox.y1);
                const int index = row * score.w + col;
                for(int channel=0;channel<4;channel++){
                    bbox.regreCoord[channel]=location.channel(channel)[index];
                }
                boundingBox_.push_back(bbox);
            }
            p++;
            //plocal++;
        }
    }
}

void MTCNN::nmsTwoBoxs(vector<Bbox>& boundingBox_, vector<Bbox>& previousBox_, const float overlap_threshold, string modelname)
{
    if (boundingBox_.empty()) {
        return;
    }
    sort(boundingBox_.begin(), boundingBox_.end(), cmpScore);
    float IOU = 0;
    float maxX = 0;
    float maxY = 0;
    float minX = 0;
    float minY = 0;
    //std::cout << boundingBox_.size() << " ";
    for (std::vector<Bbox>::iterator ity = previousBox_.begin(); ity != previousBox_.end(); ity++) {
        for (std::vector<Bbox>::iterator itx = boundingBox_.begin(); itx != boundingBox_.end();) {
            int i = itx - boundingBox_.begin();
            int j = ity - previousBox_.begin();
            maxX = std::max(boundingBox_.at(i).x1, previousBox_.at(j).x1);
            maxY = std::max(boundingBox_.at(i).y1, previousBox_.at(j).y1);
            minX = std::min(boundingBox_.at(i).x2, previousBox_.at(j).x2);
            minY = std::min(boundingBox_.at(i).y2, previousBox_.at(j).y2);
            //maxX1 and maxY1 reuse
            maxX = ((minX - maxX + 1)>0) ? (minX - maxX + 1) : 0;
            maxY = ((minY - maxY + 1)>0) ? (minY - maxY + 1) : 0;
            //IOU reuse for the area of two bbox
            IOU = maxX * maxY;
            if (!modelname.compare("Union"))
                IOU = IOU / (boundingBox_.at(i).area + previousBox_.at(j).area - IOU);
            else if (!modelname.compare("Min")) {
                IOU = IOU / ((boundingBox_.at(i).area < previousBox_.at(j).area) ? boundingBox_.at(i).area : previousBox_.at(j).area);
            }
            if (IOU > overlap_threshold&&boundingBox_.at(i).score>previousBox_.at(j).score) {
                //if (IOU > overlap_threshold) {
                itx = boundingBox_.erase(itx);
            }
            else {
                itx++;
            }
        }
    }
    //std::cout << boundingBox_.size() << std::endl;
}

void MTCNN::nms(std::vector<Bbox> &boundingBox_, const float overlap_threshold, string modelname)
{
    if(boundingBox_.empty()){
        return;
    }
    sort(boundingBox_.begin(), boundingBox_.end(), cmpScore);
    float IOU = 0;
    float maxX = 0;
    float maxY = 0;
    float minX = 0;
    float minY = 0;
    std::vector<int> vPick;
    int nPick = 0;
    std::multimap<float, int> vScores;
    const int num_boxes = boundingBox_.size();
    vPick.resize(num_boxes);
    for (int i = 0; i < num_boxes; ++i){
        vScores.insert(std::pair<float, int>(boundingBox_[i].score, i));
    }
    while(vScores.size() > 0){
        int last = vScores.rbegin()->second;
        vPick[nPick] = last;
        nPick += 1;
        for (std::multimap<float, int>::iterator it = vScores.begin(); it != vScores.end();){
            int it_idx = it->second;
            maxX = std::max(boundingBox_.at(it_idx).x1, boundingBox_.at(last).x1);
            maxY = std::max(boundingBox_.at(it_idx).y1, boundingBox_.at(last).y1);
            minX = std::min(boundingBox_.at(it_idx).x2, boundingBox_.at(last).x2);
            minY = std::min(boundingBox_.at(it_idx).y2, boundingBox_.at(last).y2);
            //maxX1 and maxY1 reuse
            maxX = ((minX-maxX+1)>0)? (minX-maxX+1) : 0;
            maxY = ((minY-maxY+1)>0)? (minY-maxY+1) : 0;
            //IOU reuse for the area of two bbox
            IOU = maxX * maxY;
            if(!modelname.compare("Union"))
                IOU = IOU/(boundingBox_.at(it_idx).area + boundingBox_.at(last).area - IOU);
            else if(!modelname.compare("Min")){
                IOU = IOU/((boundingBox_.at(it_idx).area < boundingBox_.at(last).area)? boundingBox_.at(it_idx).area : boundingBox_.at(last).area);
            }
            if(IOU > overlap_threshold){
                it = vScores.erase(it);
            }else{
                it++;
            }
        }
    }
    
    vPick.resize(nPick);
    std::vector<Bbox> tmp_;
    tmp_.resize(nPick);
    for(int i = 0; i < nPick; i++){
        tmp_[i] = boundingBox_[vPick[i]];
    }
    boundingBox_ = tmp_;
}

void MTCNN::refine(vector<Bbox> &vecBbox, const int &height, const int &width, bool square)
{
    if(vecBbox.empty()){
        cout<<"Bbox is empty!!"<<endl;
        return;
    }
    float bbw=0, bbh=0, maxSide=0;
    float h = 0, w = 0;
    float x1=0, y1=0, x2=0, y2=0;
    for(vector<Bbox>::iterator it=vecBbox.begin(); it!=vecBbox.end();it++){
        bbw = (*it).x2 - (*it).x1 + 1;
        bbh = (*it).y2 - (*it).y1 + 1;
        x1 = (*it).x1 + (*it).regreCoord[0]*bbw;
        y1 = (*it).y1 + (*it).regreCoord[1]*bbh;
        x2 = (*it).x2 + (*it).regreCoord[2]*bbw;
        y2 = (*it).y2 + (*it).regreCoord[3]*bbh;
        
        
        
        if(square){
            w = x2 - x1 + 1;
            h = y2 - y1 + 1;
            maxSide = (h>w)?h:w;
            x1 = x1 + w*0.5 - maxSide*0.5;
            y1 = y1 + h*0.5 - maxSide*0.5;
            (*it).x2 = round(x1 + maxSide - 1);
            (*it).y2 = round(y1 + maxSide - 1);
            (*it).x1 = round(x1);
            (*it).y1 = round(y1);
        }
        
        //boundary check
        if((*it).x1<0)(*it).x1=0;
        if((*it).y1<0)(*it).y1=0;
        if((*it).x2>width)(*it).x2 = width - 1;
        if((*it).y2>height)(*it).y2 = height - 1;
        
        it->area = (it->x2 - it->x1)*(it->y2 - it->y1);
    }
}

void MTCNN::extractMaxFace(vector<Bbox>& boundingBox_)
{
    if (boundingBox_.empty()) {
        return;
    }
    sort(boundingBox_.begin(), boundingBox_.end(), cmpArea);
    for (std::vector<Bbox>::iterator itx = boundingBox_.begin() + 1; itx != boundingBox_.end();) {
        itx = boundingBox_.erase(itx);
    }
}

void MTCNN::PNet(float scale)
{
    //first stage
    int hs = (int)ceil(img_h*scale);
    int ws = (int)ceil(img_w*scale);
    ncnn::Mat in;
    resize_bilinear(img, in, ws, hs);
    ncnn::Extractor ex = Pnet.create_extractor();
    ex.set_light_mode(true);
    //sex.set_num_threads(4);
    ex.input("data", in);
    ncnn::Mat score_, location_;
    ex.extract("prob1", score_);
    ex.extract("conv4-2", location_);
    std::vector<Bbox> boundingBox_;
    
    generateBbox(score_, location_, boundingBox_, scale);
    nms(boundingBox_, nms_threshold[0]);
    
    firstBbox_.insert(firstBbox_.end(), boundingBox_.begin(), boundingBox_.end());
    boundingBox_.clear();
}

void MTCNN::PNet()
{
    firstBbox_.clear();
    float minl = img_w < img_h? img_w: img_h;
    float m = (float)MIN_DET_SIZE/minsize;
    minl *= m;
    float factor = pre_facetor;
    vector<float> scales_;
    while(minl>MIN_DET_SIZE){
        scales_.push_back(m);
        minl *= factor;
        m = m*factor;
    }
    for (size_t i = 0; i < scales_.size(); i++) {
        int hs = (int)ceil(img_h*scales_[i]);
        int ws = (int)ceil(img_w*scales_[i]);
        ncnn::Mat in;
        resize_bilinear(img, in, ws, hs);
        ncnn::Extractor ex = Pnet.create_extractor();
        //ex.set_num_threads(2);
        ex.set_light_mode(true);
        ex.input("data", in);
        ncnn::Mat score_, location_;
        ex.extract("prob1", score_);
        ex.extract("conv4-2", location_);
        std::vector<Bbox> boundingBox_;
        generateBbox(score_, location_, boundingBox_, scales_[i]);
        nms(boundingBox_, nms_threshold[0]);
        firstBbox_.insert(firstBbox_.end(), boundingBox_.begin(), boundingBox_.end());
        boundingBox_.clear();
    }
}

void MTCNN::RNet()
{
    secondBbox_.clear();
    int count = 0;
    for(vector<Bbox>::iterator it=firstBbox_.begin(); it!=firstBbox_.end();it++){
        ncnn::Mat tempIm;
        copy_cut_border(img, tempIm, (*it).y1, img_h-(*it).y2, (*it).x1, img_w-(*it).x2);
        ncnn::Mat in;
        resize_bilinear(tempIm, in, 24, 24);
        ncnn::Extractor ex = Rnet.create_extractor();
        //ex.set_num_threads(2);
        ex.set_light_mode(true);
        ex.input("data", in);
        ncnn::Mat score, bbox;
        ex.extract("prob1", score);
        ex.extract("conv5-2", bbox);
        if ((float)score[1] > threshold[1]) {
            for (int channel = 0; channel<4; channel++) {
                it->regreCoord[channel] = (float)bbox[channel];//*(bbox.data+channel*bbox.cstep);
            }
            it->area = (it->x2 - it->x1)*(it->y2 - it->y1);
            it->score = score.channel(1)[0];//*(score.data+score.cstep);
            secondBbox_.push_back(*it);
        }
    }
}

void MTCNN::ONet()
{
    thirdBbox_.clear();
    for(vector<Bbox>::iterator it=secondBbox_.begin(); it!=secondBbox_.end();it++){
        ncnn::Mat tempIm;
        copy_cut_border(img, tempIm, (*it).y1, img_h-(*it).y2, (*it).x1, img_w-(*it).x2);
        ncnn::Mat in;
        resize_bilinear(tempIm, in, 48, 48);
        ncnn::Extractor ex = Onet.create_extractor();
        //ex.set_num_threads(2);
        ex.set_light_mode(true);
        ex.input("data", in);
        ncnn::Mat score, bbox, keyPoint;
        ex.extract("prob1", score);
        ex.extract("conv6-2", bbox);
        ex.extract("conv6-3", keyPoint);
        if ((float)score[1] > threshold[2]) {
            for (int channel = 0; channel < 4; channel++) {
                it->regreCoord[channel] = (float)bbox[channel];
            }
            it->area = (it->x2 - it->x1) * (it->y2 - it->y1);
            it->score = score.channel(1)[0];
            for (int num = 0; num<5; num++) {
                (it->ppoint)[num] = it->x1 + (it->x2 - it->x1) * keyPoint[num];
                (it->ppoint)[num + 5] = it->y1 + (it->y2 - it->y1) * keyPoint[num + 5];
            }
            
            thirdBbox_.push_back(*it);
        }
    }
}

void MTCNN::detect(ncnn::Mat& img_, std::vector<Bbox>& finalBbox_)
{
    img = img_;
    img_w = img.w;
    img_h = img.h;
    img.substract_mean_normalize(mean_vals, norm_vals);
    
    PNet();
    //the first stage's nms
    if(firstBbox_.size() < 1) return;
    nms(firstBbox_, nms_threshold[0]);
    refine(firstBbox_, img_h, img_w, true);
    //printf("firstBbox_.size()=%d\n", firstBbox_.size());
    
    
    //second stage
    RNet();
    //printf("secondBbox_.size()=%d\n", secondBbox_.size());
    if(secondBbox_.size() < 1) return;
    nms(secondBbox_, nms_threshold[1]);
    refine(secondBbox_, img_h, img_w, true);
    
    //third stage
    ONet();
    //printf("thirdBbox_.size()=%d\n", thirdBbox_.size());
    if(thirdBbox_.size() < 1) return;
    refine(thirdBbox_, img_h, img_w, true);
    nms(thirdBbox_, nms_threshold[2], "Min");
    finalBbox_ = thirdBbox_;
}

void MTCNN::detectMaxFace(ncnn::Mat& img_, std::vector<Bbox>& finalBbox)
{
    firstPreviousBbox_.clear();
    secondPreviousBbox_.clear();
    thirdPrevioussBbox_.clear();
    firstBbox_.clear();
    secondBbox_.clear();
    thirdBbox_.clear();
    
    //norm
    img = img_;
    img_w = img.w;
    img_h = img.h;
    img.substract_mean_normalize(mean_vals, norm_vals);
    
    //pyramid size
    float minl = img_w < img_h ? img_w : img_h;
    float m = (float)MIN_DET_SIZE / minsize;
    minl *= m;
    float factor = pre_facetor;
    vector<float> scales_;
    while (minl>MIN_DET_SIZE) {
        scales_.push_back(m);
        minl *= factor;
        m = m*factor;
    }
    sort(scales_.begin(), scales_.end());
    //printf("scales_.size()=%d\n", scales_.size());
    
    //Change the sampling process.
    for (size_t i = 0; i < scales_.size(); i++)
    {
        //first stage
        PNet(scales_[i]);
        nms(firstBbox_, nms_threshold[0]);
        nmsTwoBoxs(firstBbox_, firstPreviousBbox_, nms_threshold[0]);
        if (firstBbox_.size() < 1) {
            firstBbox_.clear();
            continue;
        }
        firstPreviousBbox_.insert(firstPreviousBbox_.end(), firstBbox_.begin(), firstBbox_.end());
        refine(firstBbox_, img_h, img_w, true);
        //printf("firstBbox_.size()=%d\n", firstBbox_.size());
        
        //second stage
        RNet();
        nms(secondBbox_, nms_threshold[1]);
        nmsTwoBoxs(secondBbox_, secondPreviousBbox_, nms_threshold[0]);
        secondPreviousBbox_.insert(secondPreviousBbox_.end(), secondBbox_.begin(), secondBbox_.end());
        if (secondBbox_.size() < 1) {
            firstBbox_.clear();
            secondBbox_.clear();
            continue;
        }
        refine(secondBbox_, img_h, img_w, true);
        //printf("secondBbox_.size()=%d\n", secondBbox_.size());
        
        //third stage
        ONet();
        //printf("thirdBbox_.size()=%d\n", thirdBbox_.size());
        if (thirdBbox_.size() < 1) {
            firstBbox_.clear();
            secondBbox_.clear();
            thirdBbox_.clear();
            continue;
        }
        refine(thirdBbox_, img_h, img_w, true);
        nms(thirdBbox_, nms_threshold[2], "Min");
        
        if (thirdBbox_.size() > 0) {
            extractMaxFace(thirdBbox_);
            finalBbox = thirdBbox_;//if largest face size is similar,.
            break;
        }
    }
    
    //printf("firstPreviousBbox_.size()=%d\n", firstPreviousBbox_.size());
    //printf("secondPreviousBbox_.size()=%d\n", secondPreviousBbox_.size());
}
//////////////////// MTCNN PART END ////////////////////
///landmarker
NSString *flBinPath = [[NSBundle mainBundle] pathForResource:@"fl" ofType:@"bin"];
NSString *flParamPath = [[NSBundle mainBundle] pathForResource:@"fl" ofType:@"param"];
class ZQLandmarker {
public:
    ZQLandmarker();
    ~ZQLandmarker();

    int LoadModel();
    int ExtractKeypoints(const cv::Mat& img_src,
        const cv::Rect& face, std::vector<cv::Point2f>* keypoints);

private:
    ncnn::Net* zq_landmarker_net_;
    const float meanVals[3] = { 127.5f, 127.5f, 127.5f };
    const float normVals[3] = { 0.0078125f, 0.0078125f, 0.0078125f };
    bool initialized;
};

float getDistance(cv::Point2f pointO, cv::Point2f pointA) {
    float distance;
    distance = powf((pointO.x - pointA.x), 2) + powf((pointO.y - pointA.y), 2);
    distance = sqrtf(distance);
    return distance;
}

double GetEyeAspectRatio(std::vector<cv::Point2f> keypoints) {
    float l_o = getDistance(keypoints.at(72), keypoints.at(73));
    float l_A = getDistance(keypoints.at(53), keypoints.at(57));
    float l_B = getDistance(keypoints.at(54), keypoints.at(56));
    float l_C = getDistance(keypoints.at(52), keypoints.at(55));
    float r_o = getDistance(keypoints.at(75), keypoints.at(76));
    float r_A = getDistance(keypoints.at(59), keypoints.at(63));
    float r_B = getDistance(keypoints.at(60), keypoints.at(62));
    float r_C = getDistance(keypoints.at(58), keypoints.at(61));
    double l_ear = (l_A + l_B + l_o) / (3.0 * l_C);
    double r_ear = (r_A + r_B + r_o) / (3.0 * r_C);
//    std::cout << l_ear << std::endl;
//    std::cout << r_ear << std::endl;
    return (l_ear + r_ear) / 2.0;
}

ZQLandmarker::ZQLandmarker() {
    zq_landmarker_net_ = new ncnn::Net();
    initialized = false;
#if MIRROR_VULKAN
    ncnn::create_gpu_instance();
    zq_landmarker_net_->opt.use_vulkan_compute = true;
#endif // MIRROR_VULKAN
    if (zq_landmarker_net_->load_param([flParamPath UTF8String]) == -1 ||
        zq_landmarker_net_->load_model([flBinPath UTF8String]) == -1) {
        std::cout << "load face landmark model failed." << std::endl;
        initialized = true;
    }
    initialized = true;
}

ZQLandmarker::~ZQLandmarker() {
    zq_landmarker_net_->clear();
#if MIRROR_VULKAN
    ncnn::destroy_gpu_instance();
#endif // MIRROR_VULKAN
}

int ZQLandmarker::LoadModel() {
    if (zq_landmarker_net_->load_param([flParamPath UTF8String]) == -1 ||
        zq_landmarker_net_->load_model([flBinPath UTF8String]) == -1) {
        std::cout << "load face landmark model failed." << std::endl;
        return 10000;
    }
    initialized = true;
    return 0;
}

int ZQLandmarker::ExtractKeypoints(const cv::Mat & img_src,
    const cv::Rect & face, std::vector<cv::Point2f>* keypoints) {
    std::cout << "start extract keypoints." << std::endl;
    keypoints->clear();
    if (!initialized) {
        std::cout << "zq landmarker unitialized." << std::endl;
        return 10000;
    }

    if (img_src.empty()) {
        std::cout << "input empty." << std::endl;
        return 10001;
    }

    cv::Mat img_face = img_src(face).clone();
    ncnn::Extractor ex = zq_landmarker_net_->create_extractor();
    ncnn::Mat in = ncnn::Mat::from_pixels_resize(img_face.data,
        ncnn::Mat::PIXEL_BGR, img_face.cols, img_face.rows, 112, 112);
    in.substract_mean_normalize(meanVals, normVals);
    ex.input("data", in);
    ncnn::Mat out;
    ex.extract("bn6_3", out);

    for (int i = 0; i < 106; ++i) {
        float x = abs(out[2 * i] * img_face.cols) + face.x;
        float y = abs(out[2 * i + 1] * img_face.rows) + face.y;
        keypoints->push_back(cv::Point2f(x, y));
    }
    std::cout << "end extract keypoints." << std::endl;
    return 0;
}
///


//////////////////// MAIN PART BEG ////////////////////

#define MAXFACEOPEN 1 //设置是否开关最大人脸调试，1为开，其它为关
MTCNN mtcnn;
ZQLandmarker zqlandmarker;
float threshold_blink = 0.15;
int total_blink = 0;
int current_blink = 0;

void detect_faces(cv::Mat& image)
{
    clock_t start_time = clock();
    
    ncnn::Mat ncnn_img = ncnn::Mat::from_pixels(image.data, ncnn::Mat::PIXEL_BGR2RGB, image.cols, image.rows);
    std::vector<Bbox> finalBbox;
    
#if(MAXFACEOPEN==1)
    mtcnn.detectMaxFace(ncnn_img, finalBbox);
#else
    mtcnn.detect(ncnn_img, finalBbox);
#endif
    
    const int num_box = (int)finalBbox.size();
    std::vector<cv::Rect> bbox;
    bbox.resize(num_box);

    for(int i = 0; i < num_box; i++){
        cv::Rect r = cv::Rect(finalBbox[0].x1, finalBbox[0].y1, finalBbox[0].x2 - finalBbox[0].x1 + 1, finalBbox[0].y2 - finalBbox[0].y1 + 1);
    
        (r.x < 0) && (r.x = 0);
        (r.y < 0) && (r.y = 0);
        (r.width > image.cols - 1) && (r.width = image.cols - 1);
        (r.height > image.rows - 1) && (r.height = image.rows - 1);
        
        if (
            !(0 <= r.x && 0 <= r.width && r.x + r.width <= image.cols && 0 <= r.y && 0 <= r.height && r.y + r.height <= image.rows) ||
            (r.width < 20) ||
            (r.height < 20)
            ) {
            continue;
        }
//        cv::Mat ROI(image, r);
        vector<cv::Point2f> keypoints;
        zqlandmarker.ExtractKeypoints(image, r, &keypoints);
        if (keypoints.size() == 106) {
            for (int j = 0; j < static_cast<int>(keypoints.size()); ++j) {
                cv::circle(image, keypoints[j], 1, cv::Scalar(0, 0, 255), 1);
            }
            double ear = GetEyeAspectRatio(keypoints);
            if (ear <= threshold_blink) {
                current_blink += 1;
            } else {
                if (current_blink >= 3) {
                    total_blink += 1;
                }
                current_blink = 0;
            }
            cv::putText(image, "EAR: " + std::to_string(ear), cvPoint(10, 30),
                        cv::FONT_HERSHEY_SIMPLEX, 0.7, cv::Scalar(0, 0, 255), 2);
            cv::putText(image, "Blink: " + std::to_string(total_blink), cvPoint(10, 50),
                        cv::FONT_HERSHEY_SIMPLEX, 0.7, cv::Scalar(0, 0, 255), 2);
        }
        rectangle(image, r, Scalar(0, 0, 255), 2, 8, 0);
//            for (int j = 0; j<5; j = j + 1)
//            {
//                cv::circle(image, cvPoint(finalBbox[i].ppoint[j], finalBbox[i].ppoint[j + 5]), 2, CV_RGB(0, 255, 0), CV_FILLED);
//            }
    }

    clock_t finish_time = clock();
    double total_time = (double)(finish_time - start_time) / CLOCKS_PER_SEC;
    std::cout << "time" << total_time * 1000 << "ms" << std::endl;
}

//////////////////// MAIN PART END ////////////////////

/// Converts an UIImage to Mat.
/// Orientation of UIImage will be lost.
static void UIImageToMat(UIImage *image, cv::Mat &mat) {
    assert(image.size.width > 0 && image.size.height);
    assert(image.CGImage != nil || image.CIImage != nil);
    
    // Create a pixel buffer.
    NSInteger width = image.size.width;
    NSInteger height = image.size.height;
    cv::Mat mat8uc4 = cv::Mat((int)height, (int)width, CV_8UC4);
    
    // Draw all pixels to the buffer.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (image.CGImage) {
        // Render with using Core Graphics.
        CGContextRef contextRef = CGBitmapContextCreate(mat8uc4.data, mat8uc4.cols, mat8uc4.rows, 8, mat8uc4.step, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
        CGContextDrawImage(contextRef, CGRectMake(0, 0, width, height), image.CGImage);
        CGContextRelease(contextRef);
    } else {
        // Render with using Core Image.
        static CIContext* context = nil; // I do not like this declaration contains 'static'. But it is for performance.
        if (!context) {
            context = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
        }
        CGRect bounds = CGRectMake(0, 0, width, height);
        [context render:image.CIImage toBitmap:mat8uc4.data rowBytes:mat8uc4.step bounds:bounds format:kCIFormatRGBA8 colorSpace:colorSpace];
    }
    CGColorSpaceRelease(colorSpace);
    
    // Adjust byte order of pixel.
    cv::Mat mat8uc3 = cv::Mat((int)width, (int)height, CV_8UC3);
    cv::cvtColor(mat8uc4, mat8uc3, CV_RGBA2BGR);
    
    mat = mat8uc3;
}

/// Converts a Mat to UIImage.
static UIImage *MatToUIImage(cv::Mat &mat) {
    
    // Create a pixel buffer.
    assert(mat.elemSize() == 1 || mat.elemSize() == 3);
    cv::Mat matrgb;
    if (mat.elemSize() == 1) {
        cv::cvtColor(mat, matrgb, CV_GRAY2RGB);
    } else if (mat.elemSize() == 3) {
        cv::cvtColor(mat, matrgb, CV_BGR2RGB);
    }
    
    // Change a image format.
    NSData *data = [NSData dataWithBytes:matrgb.data length:(matrgb.elemSize() * matrgb.total())];
    CGColorSpaceRef colorSpace;
    if (matrgb.elemSize() == 1) {
        colorSpace = CGColorSpaceCreateDeviceGray();
    } else {
        colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef imageRef = CGImageCreate(matrgb.cols, matrgb.rows, 8, 8 * matrgb.elemSize(), matrgb.step.p[0], colorSpace, kCGImageAlphaNone|kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *image = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
    return image;
}

/// Restore the orientation to image.
static UIImage *RestoreUIImageOrientation(UIImage *processed, UIImage *original) {
    if (processed.imageOrientation == original.imageOrientation) {
        return processed;
    }
    return [UIImage imageWithCGImage:processed.CGImage scale:1.0 orientation:original.imageOrientation];
}

@implementation NCNNWrapper

+(nonnull UIImage *)cvtColorBGR2GRAY:(nonnull UIImage *)image {
    cv::Mat bgrMat;
    UIImageToMat(image, bgrMat);
    cv::Mat grayMat;
    cv::cvtColor(bgrMat, grayMat, CV_BGR2GRAY);
    UIImage *grayImage = MatToUIImage(grayMat);
    return RestoreUIImageOrientation(grayImage, image);
}

+(nonnull NSString *)openCVVersionString
{
    return [NSString stringWithFormat:@"OpenCV Version %s",  CV_VERSION];
}

+(nonnull UIImage *)detectFace:(nonnull UIImage *)rawImage {
    cv::Mat bgrMat;
    UIImage* image = rawImage;

    // 这里有一个大坑的地方就是，所有网上的资料都是直接使用UIImageToMat方法将UIImage和Mat进行转换的，这样是不行的，
    // 因此直接用iPhone拍的照片会在转化的过程中顺时针转动90度，所以我们需要将原图如下处理后才可以得到正着的图片

//    UIGraphicsBeginImageContext(image.size);
//    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
//    image = UIGraphicsGetImageFromCurrentImageContext();
//    UIGraphicsEndImageContext();

    UIImageToMat(image, bgrMat);
    detect_faces(bgrMat);

    return MatToUIImage(bgrMat);
}

@end
