####################################################################################
# Name: Delmarva Model Inputs
# Coder: C. Nathan Jones
# Date: 19 Jan 2019
# Purpose: Organize Model Inputs for PPR
####################################################################################

####################################################################################
# Step 1: Setup Worskspace ---------------------------------------------------------
####################################################################################
# 1a. Clear Memory  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rm(list=ls(all=TRUE))

# 1b. Load Packages ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
library(sp)         # for spatial analysis
library(raster)     # for spatial analysis
library(rgdal)      # for spatial analysis
library(rgeos)      # for spatial analysis
library(dplyr)      # for data processing
library(rslurm)     # parallel computing
library(geosphere)  # for spatial analysis
library(parallel)   # for parallel computing



# 1c. Define data dir ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
wd<-"//nfs/WHC-data/Regional_Analysis/PPR/"  # Define working directory for later reference

####################################################################################
# Step 2: Spatial data -------------------------------------------------------------
####################################################################################
# 2.1 Define master projection
p<-CRS("+proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=23 +lon_0=-96 +x_0=0 +y_0=0 +datum=NAD83 +units=m +no_defs +ellps=GRS80 +towgs84=0,0,0")

# 2.2 Wetland shape
wetlands.shp<-readOGR(paste0(wd,"inputs/."),"wetlands")
wetlands.shp<-spTransform(wetlands.shp, p)

# 2.3 HUC12 shape
HUC12.shp<-readOGR(paste0(wd,"inputs/."),"HUC12")   
HUC12.shp<-spTransform(HUC12.shp, p)               

# 2.4 Catchment shape  
catchments.shp<-readOGR(paste0(wd,"inputs/."),"catchments")
catchments.shp<-spTransform(catchments.shp, p)     

#2.5 flowline shape
flowlines.shp<-readOGR(paste0(wd,"inputs/."),"flow_net")                              
flowlines.shp<-spTransform(flowlines.shp, p)       

#2.5 flow accumulation
fac.grd<-raster(paste0(wd,"inputs/fac2"))  
fac.grd<-projectRaster(fac.grd, crs=p)

#2.6 soils
soils.shp<-readOGR(paste0(wd,"inputs/."),"soils")                                    
soils.shp<-spTransform(soils.shp, p)               
soils.shp<-merge(soils.shp, read.csv("data/soils_lookup.csv"), by.x='MUKEY', by.y="mukey")

#2.7 digital elevation model
dem.grd<-raster(paste0(wd,"inputs/dem_cm"))                   
mask<-spTransform(catchments.shp, dem.grd@crs)  
dem.grd<-crop(dem.grd, mask)                    
remove(mask)                                                              
dem.grd<-projectRaster(dem.grd, crs=p)   

#2.8 Nonfloodplain wetlands from Lane and D'Amico 2016
nfw_centroid.shp<-readOGR(paste0(wd,"inputs/."),"NFW_centroids")                     
nfw_centroid.shp<-spTransform(nfw_centroid.shp, p)

#2.9 Rooting depth grid
rootdepth.grd<-raster(paste0(wd,"inputs/rootdepth"))                   
rootdepth.grd<-projectRaster(rootdepth.grd, crs=p)   
rootdepth.grd<-raster::resample(rootdepth.grd, dem.grd)  

####################################################################################
# Step 3: Wetland Processing--------------------------------------------------------
####################################################################################
#3.1 add WetID column to shp file using sequence from 1:total num of wetlands
wetlands.shp@data$WetID<-seq(1,length(wetlands.shp)) 

#3.2 Delineate "Isolated" Wetlands  (Use NFW from Lane and D'Amico 2016) 
wetlands.shp<-wetlands.shp[nfw_centroid.shp,] 

#3.3 Estimate wetland area
wetlands.shp$area_m2<-gArea(wetlands.shp,byid=T) # Caclculate wetland area

#3.4 Estimate 1/2 distance to nearest wetlands [dL]
wetlandCentroid <- centroid(wetlands.shp)                                   # get centroid of each wetland
distMat <- pointDistance(wetlandCentroid, lonlat = FALSE)                   # get the distances to each other point
diag(distMat) <- NA                                                         # replace the diagonal's zeros with NAs
wetlands.shp$dist2NearWet <- apply(distMat, 1, min, na.rm=TRUE)/2           # put the half distances into variable

#3.5 Estimate dLe
#download function
source("R/divide_dist.R")
#run function
dLe<-mclapply(
  X=seq(1, length(catchments.shp)), 
  FUN=divide_dist.fun, 
  mc.silent = T, 
  mc.cores = detectCores()
)
dLe<-do.call(rbind, dLe)
dLe<-data.frame(dLe)
colnames(dLe)<-c("WetID","dLe")
dLe<-dLe[dLe$WetID!=0,]
dLe<-dLe[!duplicated(dLe[,1]),]

#Merge with wetlands.shp
wetlands.shp<-merge(wetlands.shp, dLe, by="WetID")
remove(dLe)

####################################################################################
# Step 4: Climate data--------------------------------------------------------------
####################################################################################
source("R/climate_sim.R")
climate<-climate_sim(ncdc_file_path = paste0(wd,"inputs/ncdc_Jamestown.csv"), 
                     lat_degrees    = 46.9, 
                     elevation      = 1400 * 0.3048)
pet.VAR<-climate$pet.VAR
precip.VAR<-climate$precip.VAR
remove(climate)


qc <- data.frame(precip.VAR)
qc$pet.VAR <- pet.VAR
names(qc) <- c("PRECIP", "PET")
qc$day <- rep(seq(1,365), times = 1000)
qc$year <- rep(seq(1,1000), each = 365)

qc_summary_ann <- qc %>%
  group_by(year) %>%
  summarise(sum_P = sum(PRECIP), sum_PET = sum(PET)) 

mean(qc_summary_ann$sum_P)
mean(qc_summary_ann$sum_PET)

qc_summary_daily<- qc %>%
  group_by(day) %>%
  summarise(mean_P = mean(PRECIP), mean_PET = mean(PET)) 

library(ggplot2)

ggplot(data = qc, aes(x = day, y = PRECIP, group = year)) + 
  geom_line(alpha = 0.05)
