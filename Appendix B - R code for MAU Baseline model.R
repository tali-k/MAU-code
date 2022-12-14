# Code for simulation model of one MAU using model occupancy - this is the baseline model but can be also used for merging MAUs
# Authors: Meetali Kakad and Fredrik Dahl
#=================================================================
# Model updates patients list for discharges and new patients daily
# We only include patients who spend a minimum of one night!
# Assumes that beds resulting from discharges have a 50% probability of being available for new admission over the day

# Install packages
library(tidyverse)
library(dplyr)
library(magrittr)
library(lubridate)
library(ggplot2)

setwd()
# Sys.setlocale("LC_TIME", "C")

RNGkind(sample.kind = "Rounding")
# Set random seed
set.seed(123)

# Source file paths
source("~/DES_KAD/file_paths2.R")

# Import and modify input tables ------
# Import tables of admission and discharge regression coefficients
adm_coefficients <- read_csv("~/adm_coefficients_exp1.csv") # unconstrained demand coefficients
dis_coefficients <- read_csv("~dis_coefficients.csv")

# Number of beds per unit
capacity <- tibble(
  MAU_name = c(
    3, 1, 2, 4
  ),
  beds = c(72, 14, 6, 15)
)

model_d <- "log_wkdy"

# Create admission and discharge functions -------

generate_admissions <- function(MAU_list, current_date) { # occupancy not included as unconstrained demand model
  # Returns a (random) list of new patient stays
  
  # Create empty dataframe to collect admissions generated by each MAU
  all_new <- matrix(0, 0, 3)
  colnames(all_new) <- c("MAU", "in_date", "out_date")
  all_new <- as_tibble(all_new)
  
  for (MAU in MAU_list) {
    
    # Identify day of week and month of year corresponding to current_date
    day_of_week <- wday(current_date + day_zero) # In R wday command starts on Sunday i.e. Monday is 2
    # As we add current_date to day_zero, first wday is 1.1.2017
    month_of_year <- month(current_date + day_zero)
    
    # Use coefficients from previous admission regression to generate expected value for number of admissions(Y)
    
    # Extract coefficients
    
    # Admission coefficients
    coeff <- adm_coefficients %>%
      filter(MAU_name == MAU) # Filter for MAU
    
    # Intercept
    intercept <- coeff %>%
      filter(Term == "(Intercept)") %$%
      Coefficient
    
    # Day of week
    if (day_of_week > 1) {
      coeff_weekday <- coeff %>%
        filter(Term == paste0("Weekday", day_of_week)) %$%
        Coefficient
    } else {
      coeff_weekday <- 0
    }
    
    # Month
    if (month_of_year > 1) {
      coeff_month <- coeff %>%
        filter(Term == paste0("Month", month_of_year)) %$%
        Coefficient
    } else {
      coeff_month <- 0
    }
    
    # Populate formula to generate expected value
    expected <- intercept + coeff_weekday + coeff_month
    expected <- max(expected, 0.0001) # 0.0001 as episilon i.e. a very small positive number replaces -ve expected values
    
    # Use absolute value of admissions as lambda in Poisson distribution to determine the number of arrivals that day
    arrivals <- rpois(1, expected)
    
    # Create an empty matrix that we will add new admissions to
    output <- matrix(0, 0, 3)
    
    # Create and return a list of new admissions of length = arrivals
    if (arrivals == 0) {
      output
    } else {
      for (i in 1:arrivals) {
        output <- rbind(output, c(
          MAU,
          current_date, NA
        ))
      }
      colnames(output) <- c("MAU", "in_date", "out_date")
      output <- as_tibble(output)
      # return(output)
      all_new <- rbind(all_new, output)
    }
  }
  all_new
  rows <- sample(nrow(all_new))
  all_new <- all_new[rows, ]
  return(all_new)
}

patient_discharged <- function(current_date, stay) { # Use coefficients from discharge regression to generate probability of discharge p
  
  MAU <- stay[1]
  in_date <- stay[2]
  out_date <- stay[3]
  
  # Identify day of week and month of year corresponding to current_date
  day_of_week <- wday(current_date + day_zero) # In R wday command starts on Sunday i.e. Monday is 2
  month_of_year <- month(current_date + day_zero) # remove month 20220111
  
  # Extract coefficients
  
  # Discharge coefficients
  coeff_d <- dis_coefficients %>%
    filter(
      MAU_name == MAU %$% MAU,
      model == model_d # picks out the final version of discharge model, change to log_wkdy 20220112)
    ) # Filter for MAU
  
  # Intercept
  intercept_d <- coeff_d %>%
    filter(Term == "(Intercept)") %$%
    Coefficient
  
  # Day of week
  if (day_of_week > 1) {
    coeff_weekday <- coeff_d %>%
      filter(Term == paste0("Weekday", day_of_week)) %$%
      Coefficient
  } else {
    coeff_weekday <- 0
  }
  
  # Month
  # if (month_of_year > 1) {
  #   coeff_month <- coeff_d %>%
  #     filter(Term == paste0("Month", month_of_year)) %$%
  #     Coefficient
  # } else {
  #   coeff_month <- 0
  # }
  
  # Populate formula
  y <- intercept_d + coeff_weekday
  
  # Calculate odds ratio
  OR <- exp(y)
  # Convert OR to probability of discharge
  p <- OR / (1 + OR)
  # returns random TRUE/FALSE according to the regression model.
  return(runif(1) < p)
}

# Simulation ---------
# Input parameters  ===============

MAU_list <- c(
  3
  #4, 1
  #4, 2
  #4, 3, 2, 1
)
experiment <- "baseline" #for naming charts and tables
yr <- 2017
day_zero <- dmy(paste0("31.12.", (yr - 1))) # i.e. day before analysis start
runs <- 100
duration <- 372 # 1 week cool down added to 365. Cool down enables us to calculate length of stay for all patients admitted during sim. year
# ===================================

annual_average_occupancy_by_run <- array(0 * (1:runs))

# MAU-specific constants
# Total bed capacity for merged MAU

beds <- 0

for (MAU in MAU_list) {
  beds_1 <- capacity %>%
    filter(MAU_name == MAU) %$% beds
  beds <- beds + beds_1
}

# Turning this on and off adjusts the available bed capacity for merged MAUs
# beds <- beds - 5 # For 4, 1
# beds <- beds - 3 # For 4, 2
# beds <- beds - 21  # For 4, 3, 2, 1

# Yearlong simulation -----
for (run in 1:runs) {
  # Create empty dataframes and arrays
  # Capture the data per run in an array
  print(run)
  occupancy_array <- array(0, duration)
  discharge_array <- array(0, duration)
  LOS_array <- c()
  model_arrivals_array <- c() # potential arrivals generated by model
  arrivals_array <- c() # arrivals adjusted after capacity constraints applied
  
  # Save data from each run in a form easily appended to master table
  output <- data.frame("date" = 1:365)
  LOS_output <- data.frame(run = integer(), LOS = integer())
  model_arrivals_output <- data.frame("date" = 1:365)
  arrivals_output <- data.frame("date" = 1:365)
  discharge_output <- data.frame("date" = 1:365)
  
  # List of current inpatients
  stays <- matrix(0, 0, 3)
  
  for (date in -13:duration) { # dates -13 to 0 allow for 2 weeks warm up period
    occupancy <- nrow(stays)
    if (date > 0) {
      occupancy_array[date] <- occupancy
    }
    # print(c(date, occupancy))
    if (occupancy > 0) {
      for (i in 1:occupancy) {
        if (patient_discharged(date, stays[i, ])) {
          stays[i, "out_date"] <- date
          if (date >= 1 &(stays[i, "in_date"]) >= 1 & stays[i, "in_date"] <= 365) { 
            LOS <- date - stays[i, "in_date"] 
            LOS_array <- c(LOS_array, LOS)
          }
        }
      }
      # Count the discharged stays:
      discharges <- nrow(stays %>%
                           filter(out_date == date))
      discharge_array[date] <- discharges
      # Remove the discharged stays
      stays <- stays %>% filter(is.na(out_date))
    }
    # Generate new admissions
    new_admissions <- generate_admissions(MAU_list, date)
    model_arrivals_array[date] <- nrow(new_admissions)
    
    # Add the new admissions to the set of stays:
    stays <- rbind(stays, new_admissions) 
    stays_pre <- nrow(stays) 
    tmp = 0
    if (date>0)
      tmp <- rbinom(1,discharge_array[date],0.5) # our heuristic states that 50% of beds from discharged patients will be made available on the same day
    if (min(nrow(stays), beds-tmp) > 0) {
      stays <- stays[1:min(nrow(stays), beds-tmp), ]
    }
    
    # Adjust number of arrivals by substracting number turned away
    arrivals_array[date] <- nrow(new_admissions) - (stays_pre - nrow(stays))
    
  }
  
  annual_average_occupancy_by_run[run] = mean(occupancy_array[1:365])
}

# Model
e = mean(annual_average_occupancy_by_run)
sd = sd(annual_average_occupancy_by_run)
d = 1.96 * sd/sqrt(runs)
uci = sprintf('%.2f',(e - d))
lci = sprintf('%.2f',(e + d))
print(e)
print(uci)
print(lci)

# Create table of results
results <- tribble(
  ~simulation, ~model, ~stat, ~value,
  experiment, model_d, "mean_occupancy", str_c(round(e, digits = 2), " (", uci, " - ", lci, ")"),
  experiment, model_d, "sd", str_c(round(sd, digits =2))) %>%
  mutate(
    MAU = toString(MAU_list),)
