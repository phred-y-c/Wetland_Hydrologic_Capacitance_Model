###################################################################################
#Name: Climate sim function
#Coder: C. Nathan Jones
#Date: 10 Jan 2019
#Purpose: Develop 1000 years of climate data for Delmarva HUC12 Simulations
##################################################################################
climate_sim<-function(ncdc_file_path, lat_degrees, elevation){
  #1 Call Required Libraries~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  library(Evapotranspiration)
  library(markovchain)
  library(lubridate)
  library(MASS)

  #2 Precip Model~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  #2.1 Gather Data
  data<-read.csv(ncdc_file_path)
  data$DATE<-strptime(data$DATE, format = "%Y-%m-%d") #convert data to POSIXlt format
  data<-data[order(data$DATE),]                       #order by date
  data<-data[data$PRCP>=0,]                           #remove -9999
  data<-data[!duplicated(data$DATE),]                 #remove duplicates
  data$PRCP<-data$PRCP*25.4                           #convert to mm
  data$temp<-(data$TMAX+data$TMIN)/2                  # calculate average temp
  data$temp<-(data$temp-32)*5/9                       # convert to celcius
  data<-data[,c("DATE","PRCP","temp")]                # create new matrix with cleaned data
  
  #2.2 Model Snowpack (Assume frozen precip <0*C and melt >3*C)
  #Roughly estimate snowfall
  data$SWE<-ifelse(data$temp<0, data$PRCP,0)  # get SWE if below freezing
  data$PRCP<-ifelse(data$temp<0, 0,data$PRCP) # supress precip if below freezing
  
  # 2c. Roughly estimate cumulative snowpack
  data$snowpack<-0
  data<-na.omit(data)
  for(i in 2:length(data[,1])){
    #Add previous days snow pack
    data$snowpack[i]<-data$snowpack[i-1]+data$SWE[i]
    #Melt [1/4 of] snowpack if >3*C
    if(data$temp[i]>3){
      data$PRCP[i]<-data$PRCP[i]+(data$snowpack[i]/4)
      data$snowpack[i]<-data$snowpack[i]*0.75
    }
  }

  #2.3 Create blank df to populate 1000 year synthetic flow record
  syn<-data.frame(seq.Date(as.Date("1000-01-01"),as.Date("1999-12-31"), "days"), 0)
  colnames(syn)<-c("date", "precip_mm")
  syn<-syn[substring(syn$date,6,10)!="02-29",] #remove leap year bullshit
  
  #2.4 Create Function to populate syn df
  one.state<-function(month){
    
    #2.4a Create dataframe of days for each month
    n.days<-data.frame(seq(1,12,1),c(31,28,31,30,31,30,31,31,30,31,30,31))
    colnames(n.days)<-c("month","days")
    
    #2.4b Set random seed
    set.seed(1)
    
    #2.4c create data.frame with sequence of dates from 1900 to 2014
    df<-data.frame(seq.Date(as.Date("1948/1/1"),as.Date("2010/06/30"), "days"),0)
    colnames(df)<-c("DATE","temp")
    
    #2.4d retreive data
    df$DATE<-paste(df$DATE)
    data$DATE<-paste(data$DATE)
    df<-merge(df, data, by="DATE", all=T)
    
    #2.4e reorganize a bit
    df<-data.frame(strptime(df$DATE, "%Y-%m-%d"), df$PRCP)
    colnames(df)<-c("DATE","PRCP")
    df<-df[substring(df$DATE,6,10)!="02-29",] #remove leap year bullshit
    df<-df[month(df$DATE)==month,]
    df$PRCP[is.na(df$PRCP)]<-0
    
    #2.4f fit gamma dist
    gamma<-fitdistr(df$PRCP[df$PRCP>0.05], "gamma")
    
    #2.4g prep df for markov model
    df<-split(df$PRCP, year(df$DATE))
    df<-matrix(unlist(df), nrow=n.days$days[n.days$month==month])
    
    #2.4h fit markov model
    df<-ifelse(df==0, "dry", "wet")
    markov<-markovchainFit(data=df, method="mle", name="name")
    df<-rmarkovchain(n=365000, object=markov$estimate, t0="dry")
    df[df=="dry"]<-0
    df[df=="wet"]<-rgamma(length( df[df=="wet"]), gamma$estimate[1],gamma$estimate[2])
    
    #2.4i Create markov time series
    period<-seq.Date(as.Date("1000/1/1"),as.Date("1999/12/31"), "days")
    period<-period[substring(period,6,10)!="02-29"]
    df<-data.frame(period,as.numeric(df))
    df<-df[as.numeric(substring(df[,1],6,7))==month, ]
    colnames(df)<-c("date", "precip")
    
    #2.4j Export df
    df
  }
  
  #2.4 create synthetic flow record
  precip.VAR<-lapply(seq(1,12), one.state)
  precip.VAR<-do.call(rbind, precip.VAR)
  precip.VAR<-precip.VAR[order(precip.VAR$date),]
  
  #3 Temperature model ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  #3.1 Collect Input Data
  data<-read.csv(ncdc_file_path)
  data<-data[data$TMAX>-1000,]
  data<-data[data$TMIN>-1000,]
  TMIN<-aggregate(data$TMIN, list(data$DATE), mean, na.rm=T)
  TMAX<-aggregate(data$TMAX, list(data$DATE), mean, na.rm=T)
  data<-merge(TMIN, TMAX, by="Group.1")
  colnames(data)<-c("DATE","TMIN","TMAX")
  data$DATE<-strptime(data$DATE, format = "%Y-%m-%d") #convert data to POSIXlt format
  #data$TMAX<-(data$TMAX-32)*4/9 
  #data$TMIN<-(data$TMIN-32)*4/9
  
  #3.2 Calculate PET
  climatedata<-data.frame(Year  = year(data$DATE), 
                          Month = month(data$DATE), 
                          Day   = day(data$DATE), 
                          Tmax  = (data$TMAX-32)*5/9, 
                          Tmin  = (data$TMIN-32)*5/9)
  climatedata<-climatedata[climatedata$Tmax>-1000,]
  climatedata<-climatedata[climatedata$Tmin>-1000,]
  climatedata<-climatedata[order(climatedata$Year),]

  #3.3 create timeseries input file (second input file)
  input<-ReadInputs(c("Tmax","Tmin"),
                    climatedata,
                    stopmissing=c(10,10,3),
                    timestep = "daily",
                    interp_missing_days = F,
                    interp_missing_entries = F,
                    interp_abnormal = F,
                    missing_method="DoY average",
                    abnormal_method="DoY average")
   
  # #3.4 create constants input file (third and final file)
  data("constants")
  constants$Elev<-elevation
  constants$lat_rad<-lat_degrees*pi/180

  #3.5 calculate ET
  df<-ET.HargreavesSamani(input, constants, ts="daily")
  pet.VAR<-df$ET.Daily
  pet.VAR[pet.VAR<0]<-0
  pet.VAR[is.na(pet.VAR)==T]<-0

  #3.6 Estimate median PET for each julian day
  data$PET<-pet.VAR
  data<-data[,c("DATE","PET")]
  data$DATE<-strptime(data$DATE, format="%Y-%m-%d")
  data$DATE<-as.POSIXlt(data$DATE, format="%Y-%m-%d")
  data$DATE<-data$DATE$yday
  data<-data.frame(seq(0,365),aggregate(data$PET, list(data$DATE), median))
  pet.VAR<-rep(data[2:366,2],1000)
  
  #4 Output list~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  list(pet.VAR=pet.VAR, precip.VAR=precip.VAR$precip)
}