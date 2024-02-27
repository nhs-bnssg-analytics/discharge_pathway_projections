library(fitdistrplus)
library(tidyverse)
library(tidymodels)

con <- switch(.Platform$OS.type,
              windows = RODBC::odbcConnect(dsn = "xsw"),
              unix = xswauth::modelling_sql_area()
)


nctr_df <-
  RODBC::sqlQuery(
    con,
    "SELECT
       [Organisation_Code_Provider]
      ,[Organisation_Code_Commissioner]
      ,[Census_Date]
      ,[NHS_Number]
      ,[Person_Stated_Gender_Code]
      ,[Person_Age]
      ,[CDS_Unique_Identifier]
      ,[Sub_ICB_Location]
      ,[Organisation_Site_Code]
      ,[Current_Ward]
      ,[Specialty_Code]
      ,[Bed_Type]
      ,[Date_Of_Admission]
      ,[BNSSG]
      ,[Local_Authority]
      ,[Criteria_To_Reside]
      ,[Date_NCTR]
      ,[Current_LOS]
      ,[Days_NCTR]
      ,[Current_Delay_Code]
      ,[Current_Covid_Status]
      ,[Planned_Date_Of_Discharge]
      ,[Date_Toc_Form_Completed]
      ,[Toc_Form_Status]
      ,[Discharge_Pathway]
      ,[DER_File_Name]
      ,[DER_Load_Timestamp]
  FROM Analyst_SQL_Area.dbo.vw_NCTR_Status_Report_Daily_JI"
  )


los_df <- nctr_df %>%
  filter(Person_Stated_Gender_Code %in% 1:2) %>%
  mutate(nhs_number = as.character(NHS_Number),
         nhs_number = if_else(is.na(nhs_number), glue::glue("unknown_{1:n()}"), nhs_number),
         sex = if_else(Person_Stated_Gender_Code == 1, "Male", "Female")) %>% 
  # mutate(nhs_number[is.na(nhs_number)] = glue::glue("unknown_{seq_along(nhs_number[is.na(nhs_number)])}"))
  group_by(nhs_number) %>%
  # take maximum date we have data for each patient
  filter(Census_Date == max(Census_Date)) %>%
  ungroup() %>%
  # keep only patients with either NCTR (we know they are ready for discharge)
  # OR whos max date recorded is before the latest data (have been discharged)
  filter(!is.na(Date_NCTR) | Census_Date != max(Census_Date)) %>%
  # Compute the fit for discharge LOS
  mutate(discharge_rdy_los = ifelse(!is.na(Date_NCTR), Current_LOS - Days_NCTR, Current_LOS + 1))  %>%
  # remove negative LOS (wrong end timestamps?)
  filter(discharge_rdy_los > 0) %>%
  filter(Organisation_Site_Code %in% c('RVJ01', 'RA701', 'RA301', 'RA7C2')) %>%
  mutate(Organisation_Site_Code = case_when(Organisation_Site_Code == 'RVJ01' ~ 'nbt',
                           Organisation_Site_Code == 'RA701' ~ 'bri',
                           Organisation_Site_Code %in% c('RA301', 'RA7C2') ~ 'weston',
                           TRUE ~ '')) %>%
  dplyr::select(
                nhs_number = nhs_number,
                site = Organisation_Site_Code,
                sex,
                age = Person_Age,
                spec = Specialty_Code,
                bed_type = Bed_Type,
                los = discharge_rdy_los
                ) %>%
  # filter outlier LOS
  filter(los < 50) # higher than Q(.99)

# attributes to join

attr_df <-
  RODBC::sqlQuery(
    con,
    "select * from (
select a.*, ROW_NUMBER() over (partition by nhs_number order by attribute_period desc) rn from
[MODELLING_SQL_AREA].[dbo].[New_Cambridge_Score] a) b where b.rn = 1"
  )



# modelling
model_df <- los_df %>%
   full_join(select(attr_df, -sex, -age) %>% mutate(nhs_number = as.character(nhs_number)),
             by = join_by(nhs_number == nhs_number)) %>%
   # na.omit() %>%
   select(los,
          #site,
          cambridge_score,
          age,
          sex,
          site,
          #spec, # spec has too many levels, some of which don't get seen enough to reliably create a model pipeline
          bed_type
          # smoking,
          # ethnicity,
          #segment
          ) %>%
  filter(sex != "Unknown",
         !is.na(los)) # remove this as only 1 case



set.seed(123)
los_split <- initial_split(model_df, strata = los)
los_train <- training(los_split)
los_test <- testing(los_split)

set.seed(234)
los_folds <- vfold_cv(model_df, strata = los)
los_folds


tree_spec <- decision_tree(
  cost_complexity = tune(),
  tree_depth = tune(),
  min_n = tune()
) %>%
  set_engine("rpart") %>%
  set_mode("regression")


tree_grid <- grid_regular(cost_complexity(),
                          tree_depth(range = c(1, 4)),
                          min_n(range = c(15, 100)), levels = 4)


tree_rec <- recipe(los ~ ., data = los_train)  %>%
    update_role(site, new_role = "site id") %>%  
    step_novel(all_nominal_predictors(), new_level = "other") %>%
    step_other(all_nominal_predictors(), threshold = 0.1)


tree_wf <- workflow() %>%
           add_model(tree_spec) %>%
           add_recipe(tree_rec)


doParallel::registerDoParallel()

set.seed(345)
tree_rs <- tune_grid(
  tree_wf,
  resamples = los_folds,
  grid = tree_grid,
  metrics = metric_set(rmse, rsq, mae, mape)
)



autoplot(tree_rs) + theme_light(base_family = "IBMPlexSans")
collect_metrics(tree_rs)

tuned_wf<- finalize_workflow(tree_wf, select_best(tree_rs, "rsq"))

tuned_wf

# final fit
tree_fit <- fit(tuned_wf, los_train)

tree <- extract_fit_engine(tree_fit)
rpart.plot::rpart.plot(tree)

# append leaf number onto original data:

los_model_df <- model_df %>%
  bake(extract_recipe(tree_fit), .) %>%
  mutate(leaf = treeClust::rpart.predict.leaves(tree, .))

ggplot(los_model_df, aes(x = los)) +
  geom_histogram() +
  stat_summary(aes(x = 0, y = los, xintercept = stat(y), group = leaf), 
               fun = median, geom = "vline", col = "blue") +
  stat_summary(aes(x = 0, y = los, xintercept = stat(y), group = leaf), 
               fun = mean, geom = "vline", col = "red") +
  facet_wrap(vars(leaf), scales = "free_y")


# fit los dists on the data at each leaf

fit_lnorm <- los_model_df %>%
             dplyr::select(leaf, los) %>%
             group_by(leaf) %>%
             nest() %>%
             mutate(fit = map(data, ~fitdist(.x$los, "lnorm"))) %>%
             mutate(fit_parms = map(fit, pluck, "estimate"))  %>%
             select(leaf, fit, fit_parms) %>%
             mutate(fit_parms = set_names(fit_parms, leaf))

# adding a 'leaf' for full population distribution

fit_lnorm <- fit_lnorm %>%
  bind_rows(los_model_df %>%
  mutate(leaf = -1) %>%
  group_by(leaf) %>%
  nest() %>%
  mutate(fit = map(data, ~fitdist(.x$los, "lnorm"))) %>%
  mutate(fit_parms = map(fit, pluck, "estimate"))  %>%
  select(leaf, fit, fit_parms) %>%
  mutate(fit_parms = set_names(fit_parms, leaf)))


# validation on test data

cdf_lnorm <- function(x, meanlog = 0, sdlog = 1){
 out <- cumsum(dlnorm(x, meanlog, sdlog))
 (out - min(out))/(max(out) - min(out))
}

validation_df <- los_test %>%
  bake(extract_recipe(tree_fit), .) %>%
  mutate(leaf = treeClust::rpart.predict.leaves(tree, .)) %>%
  left_join(fit_lnorm) %>%
  unnest_wider(fit_parms) %>%
  group_by(leaf) %>%
  nest() %>%
  mutate(meanlog = map_dbl(data, ~.x$meanlog[1])) %>%
  mutate(sdlog = map_dbl(data, ~.x$sdlog[1])) %>%
  mutate(ks_test = map(data, ~ks.test(.x$los, "plnorm") %>% tidy())) %>%
  mutate(ad_test = map(data, ~DescTools::AndersonDarlingTest(.x$los, null = "plnorm", meanlog = meanlog, sdlog = sdlog))) %>%
  mutate(cdf_plot = map(
    data,
    ~
      ggplot(.x, aes(x = los)) +
      geom_function(
        geom = "step",
        col = "black",
        fun = cdf_lnorm,
        args = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])
      ) +
      stat_ecdf(geom = "step") +
      labs(title = "CDF plot", x = "LOS", y = "CDF")+ theme_minimal()) 
    ) %>%
  mutate(qq_plot = map(
    data,
    ~
      ggplot(.x, aes(sample = los)) +
      qqplotr::stat_qq_band(distribution = "lnorm", alpha = 0.5,
                   dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) +
      qqplotr::stat_qq_line(distribution = "lnorm", col = "black",
                   dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) +
      qqplotr::stat_qq_point(distribution = "lnorm",
              dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) + 
      labs(title = "Q-Q plot", x = "Theoretical quantiles", y = "Empirical quantiles") + theme_minimal()
  )) %>%
  mutate(pp_plot = map(
    data,
    ~
      ggplot(.x, aes(sample = los)) +
      qqplotr::stat_pp_band(distribution = "lnorm", alpha = 0.5,
                            dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) +
      qqplotr::stat_pp_line(distribution = "lnorm", col = "black",
                   dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) +
      qqplotr::stat_pp_point(distribution = "lnorm",
              dparams = list(meanlog = .x$meanlog[1], sdlog = .x$sdlog[1])) + 
      labs(title = "P-P plot", x = "Theoretical probabilities", y = "Empirical probabilities") + theme_minimal()
  ))



# in order to created grid of plot duets (one CDF & QQ for each LOS leaf
# partition) NOTE: for some reason I have to use cowplot to make a duet with a
# border, which can then be wrapped using patchwork

plots <- pmap(list(validation_df$cdf_plot, validation_df$qq_plot, validation_df$ks_test),
              ~cowplot::plot_grid("bla", ..1, ..2) + theme(plot.background = element_rect(fill = NA, colour = 'black', size = 1)))
validation_plot_los <- patchwork::wrap_plots(plots)

ggsave(validation_plot_los,
       filename = "./validation/validation_plot_los.png",
       width = 20,
       height = 10,
       scale = 0.8)


saveRDS(fit_lnorm$fit, "data/dist_split.RDS")
saveRDS(tree_fit, "data/los_wf.RDS")