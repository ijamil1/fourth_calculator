suppressMessages(
  library(tidyverse)
)

suppressMessages(
  library(gt)
)


# for fg model
load('data/fg_model.Rdata', .GlobalEnv)

# for distribution of punt outcomes
punt_df <- readRDS("data/punt_data.rds")

# for go for it model
load('data/fd_model.Rdata', .GlobalEnv)

# 2pt model
load('data/two_pt_model.Rdata', .GlobalEnv)

suppressWarnings(
  # load games file for getting game total, point spread, and roof
  games <- readRDS(url("https://github.com/leesharpe/nfldata/blob/master/data/games.rds?raw=true")) %>%
    mutate(
      game_type = if_else(game_type == "REG", "reg", "post"),
    ) %>%
    mutate_at(vars(home_team, away_team), funs(case_when(
      . %in% "JAC" ~ "JAX",
      . %in% "STL" ~ "LA",
      . %in% "LAR" ~ "LA",
      . %in% "SD" ~ "LAC",
      . %in% "OAK" ~ "LV",
      TRUE ~ .
    )))
)

# data prep function
# games is the games file read above
prepare_df <- function(df, games) {
  
  home <- df$home_team
  away <- df$away_team
  yr <- df$yr
  
  # get lines and roof from games file
  lines <- games %>%
    filter(
      home_team == home,
      away_team == away,
      season == yr,
      game_type == df$type
    ) %>%
    mutate(roof = if_else(roof == "open" | roof == "closed" | is.na(roof), "retractable", roof)) %>%
    select(game_id, spread_line, total_line, roof)
  
  df %>%
    mutate(
      # fill in who receives 2h kickoff
      receive_2h_ko = case_when(
        # 1st half, home team opened game with kickoff, away team has ball
        qtr <= 2 & home_opening_kickoff == 1 & posteam == away_team ~ 1,
        # 1st half, away team opened game with kickoff, home team has ball
        qtr <= 2 & home_opening_kickoff == 0 & posteam == home_team ~ 1,
        TRUE ~ 0
      ),
      down = 4,
      season = df$yr,
      spread_line = lines$spread_line,
      total_line = lines$total_line,
      roof = lines$roof,
      half_seconds_remaining = if_else(qtr == 2 | qtr == 4, time, time + 900),
      game_seconds_remaining = if_else(qtr <= 2, half_seconds_remaining + 1800, half_seconds_remaining),
      model_roof = roof,
      # for now, assume that people are using the calculator for 2014 to present
      # this is for the go-for-it model
      era3 = dplyr::if_else(season > 2013 & season <= 2017, 1, 0),
      era4 = dplyr::if_else(season > 2017, 1, 0),
      # for field goal model
      era = 3,
      posteam_spread = if_else(posteam == home_team, spread_line, -spread_line),
      home_total = (total_line + spread_line) / 2,
      away_total = (total_line - spread_line) / 2,
      posteam_total = if_else(posteam == home_team, home_total, away_total),
      posteam_spread = dplyr::if_else(posteam == home_team, spread_line, -1 * spread_line),
      retractable = dplyr::if_else(model_roof == 'retractable', 1, 0),
      dome = dplyr::if_else(model_roof == 'dome', 1, 0),
      outdoors = dplyr::if_else(model_roof == 'outdoors', 1, 0)
    ) %>%
    return()
  
}


# helper function for switching possession and running off 6 seconds
flip_team <- function(df) {
  
  df %>%
    mutate(
      # swap timeouts
      to_pos = posteam_timeouts_remaining,
      to_def = defteam_timeouts_remaining,
      posteam_timeouts_remaining = to_def,
      defteam_timeouts_remaining = to_pos,
      # swap score
      score_differential = -score_differential,
      # 1st and 10
      down = 1, 
      ydstogo = 10, 
      # run off 6 seconds
      half_seconds_remaining = half_seconds_remaining - 6,
      game_seconds_remaining = game_seconds_remaining - 6,
      # don't let seconds go negative
      half_seconds_remaining = if_else(half_seconds_remaining < 0, 0, half_seconds_remaining),
      game_seconds_remaining = if_else(game_seconds_remaining < 0, 0, game_seconds_remaining),
      # flip receive_2h_ko var
      receive_2h_ko = case_when(
        qtr <= 2 & receive_2h_ko == 0 ~ 1,
        qtr <= 2 & receive_2h_ko == 1 ~ 0,
        TRUE ~ receive_2h_ko
      ),
      # switch posteam
      posteam = if_else(home_team == posteam, away_team, home_team)
    )
  
}

# helper function to move the game to start of 3rd Q on an end-of-half play
flip_half <- function(df) {
  
  # make half touchback after opening kickoff
  for_return <- df %>%
    mutate(
      # figure out which team gets the ball
      posteam = case_when(
        home_opening_kickoff == 1 ~ away_team,
        home_opening_kickoff == 0 ~ home_team
      ),
      qtr = 3,
      posteam_timeouts_remaining = 3,
      defteam_timeouts_remaining = 3,
      down = 1,
      ydstogo = 10,
      yardline_100 = 75,
      half_seconds_remaining = 1800,
      game_seconds_remaining = 1800,
      score_differential = if_else(
        posteam == df$posteam, score_differential, -score_differential
      ),
      receive_2h_ko = 0
    )
  
  # this helps the function get used in pipes later
  # if it's the end of half, return the update. otherwise, return original df
  if (df %>% dplyr::slice(1) %>% pull(qtr) == 2 & df %>% dplyr::slice(1) %>% pull(half_seconds_remaining) == 0) {
    return(for_return)
  } else {
    return(df)
  }
  
}

# function to get WP for field goal attempt
get_fg_wp <- function(df) {
  
  # probability field goal is made
  fg_prob <- as.numeric(mgcv::predict.bam(fg_model, newdata = df, type="response"))
  
  # don't recommend kicking when fg is over 60 yards
  fg_prob <- if_else(df$yardline_100 > 42, 0, fg_prob)
  
  # hacky way to not have crazy high probs for long kicks
  # because the bot should be conservative about recommending kicks in this region
  # for 56 through 60 yards
  fg_prob <- if_else(df$yardline_100 >= 38 & df$yardline_100 <= 42, fg_prob * .9, fg_prob)
  
  # note: if you're implementing this for your own team, provide your own estimates of your kicker's
  # true probs
  
  # win probability of kicking team if field goal is made
  fg_make_wp <- 
    1 - df %>%
    flip_team() %>%
    # win prob after receiving kickoff for touchback and other team has 3 more points
    mutate(
      yardline_100 = 75,
      score_differential = score_differential - 3
    ) %>%
    # for end of 1st half stuff
    flip_half() %>%
    nflfastR::calculate_win_probability() %>%
    mutate(
      
      # fill in end of game situation when team can kneel out clock
      # discourages punting when the other team can end the game
      vegas_wp = case_when(
        score_differential > 0 & game_seconds_remaining < 120 & defteam_timeouts_remaining == 0 ~ 1,
        score_differential > 0 & game_seconds_remaining < 80 & defteam_timeouts_remaining == 1 ~ 1,
        score_differential > 0 & game_seconds_remaining < 40 & defteam_timeouts_remaining == 2 ~ 1,
        TRUE ~ vegas_wp
      )
      
    ) %>%
    pull(vegas_wp)
  
  # win probability of kicking team if field goal is missed
  fg_miss_wp <- 
    1 - df %>%
    flip_team() %>%
    mutate(
      yardline_100 = (100 - yardline_100) - 8,
      # yardline_100 can't be bigger than 80 due to some weird nfl rule
      yardline_100 = if_else(yardline_100 > 80, 80, yardline_100)
    ) %>%
    # for end of 1st half stuff
    flip_half() %>%
    nflfastR::calculate_win_probability() %>%
    mutate(
      
      # fill in end of game situation when team can kneel out clock
      # discourages kicking when the other team can end the game after
      vegas_wp = case_when(
        score_differential > 0 & game_seconds_remaining < 120 & defteam_timeouts_remaining == 0 ~ 1,
        score_differential > 0 & game_seconds_remaining < 80 & defteam_timeouts_remaining == 1 ~ 1,
        score_differential > 0 & game_seconds_remaining < 40 & defteam_timeouts_remaining == 2 ~ 1,
        TRUE ~ vegas_wp
      )
      
    ) %>%
    pull(vegas_wp)
  
  # for end of half situations when team gets ball again after halftime
  # need to flip back WP again
  if (df %>% flip_team() %>% pull(half_seconds_remaining) == 0 & df$qtr == 2 &
    df %>% flip_team() %>% flip_half() %>% pull(posteam) == df$posteam) {
    fg_make_wp <- 1 - fg_make_wp
    fg_miss_wp <- 1 - fg_miss_wp
  }
  
  # FG win prob is weighted avg of make and miss WPs
  fg_wp <- fg_prob * fg_make_wp + (1 - fg_prob) * fg_miss_wp
  
  # bind up the probs to return for table
  results <- list(fg_wp, fg_prob, fg_miss_wp, fg_make_wp)
  
  return(results)
}

# function for punt wp
get_punt_wp <- function(df, punt_df) {
  
  # special case for end of half: just assume half ends on punt
  # and move game to start of 3rd Q
  if (df$qtr == 2 & df$half_seconds_remaining <= 6) {
    
    prob <- 1 - df %>%
      mutate(half_seconds_remaining = 0) %>%
      flip_half() %>%
      nflfastR::calculate_win_probability() %>%
      pull(vegas_wp)
    
    # in case same team gets ball again, need to flip WP back
    if (df %>% flip_team() %>% flip_half() %>% pull(posteam) == df$posteam) {
      prob <- 1 - prob
    }
    
    return(prob)
    
  # now the normal case for typical non-end-of-half punt
  } else {
    
    # get the distribution at a yard line from punt data
    punt_probs <- punt_df %>%
      filter(yardline_100 == df$yardline_100) %>%
      select(yardline_after, pct, muff)
    
    if (nrow(punt_probs) > 0) {
      
      # get punt df
      probs <- punt_probs %>%
        bind_cols(df[rep(1, nrow(punt_probs)), ]) %>%
        flip_team() %>%
        mutate(
          yardline_100 = 100 - yardline_after,
          
          # deal with punt return TD (yardline_after == 100)
          # we want punting team to be receiving a kickoff so have to flip everything back
          posteam = if_else(yardline_after == 100, df$posteam, posteam),
          yardline_100 = if_else(yardline_after == 100, as.integer(75), as.integer(yardline_100)),
          posteam_timeouts_remaining = dplyr::if_else(yardline_after == 100,
                                                      df$posteam_timeouts_remaining,
                                                      posteam_timeouts_remaining),
          defteam_timeouts_remaining = dplyr::if_else(yardline_after == 100,
                                                      df$defteam_timeouts_remaining,
                                                      defteam_timeouts_remaining),
          score_differential = if_else(yardline_after == 100, as.integer(-score_differential - 7), as.integer(score_differential)),
          receive_2h_ko = case_when(
            qtr <= 2 & receive_2h_ko == 0 & (yardline_after == 100) ~ 1,
            qtr <= 2 & receive_2h_ko == 1 & (yardline_after == 100) ~ 0,
            TRUE ~ receive_2h_ko
          ),
          
          # now deal with muffed punts (fumble lost)
          # again we need to flip everything back
          posteam = if_else(muff == 1, df$posteam, posteam),
          yardline_100 = if_else(muff == 1, as.integer(100 - yardline_100), yardline_100),
          posteam_timeouts_remaining = dplyr::if_else(muff == 1,
                                                      df$posteam_timeouts_remaining,
                                                      posteam_timeouts_remaining),
          defteam_timeouts_remaining = dplyr::if_else(muff == 1,
                                                      df$defteam_timeouts_remaining,
                                                      defteam_timeouts_remaining),
          score_differential = if_else(muff == 1, as.integer(-score_differential), as.integer(score_differential)),
          receive_2h_ko = case_when(
            qtr <= 2 & receive_2h_ko == 0 & (muff == 1) ~ 1,
            qtr <= 2 & receive_2h_ko == 1 & (muff == 1) ~ 0,
            TRUE ~ receive_2h_ko
          ),
          ydstogo = if_else(yardline_100 < 10, yardline_100, as.integer(ydstogo))
        ) %>%
        flip_half()
      
      # have to flip bc other team
      1 - probs %>%
        nflfastR::calculate_win_probability() %>%
        mutate(
          # for the punt return TD or muff case: punting team will have ball again, so flip WP
          vegas_wp = if_else((yardline_after == 100 | muff == 1), 1 - vegas_wp, vegas_wp),
          
          # fill in end of game situation when team can kneel out clock
          # discourages punting when the other team can end the game
          vegas_wp = case_when(
            score_differential > 0 & game_seconds_remaining < 120 & defteam_timeouts_remaining == 0 ~ 1,
            score_differential > 0 & game_seconds_remaining < 80 & defteam_timeouts_remaining == 1 ~ 1,
            score_differential > 0 & game_seconds_remaining < 40 & defteam_timeouts_remaining == 2 ~ 1,
            TRUE ~ vegas_wp
          ),
          
          wt_wp = pct * vegas_wp
        ) %>%
        summarize(wp = sum(wt_wp)) %>%
        pull(wp) %>%
        return()
    } else {
      # too close for punting
      return(NA_real_)
    }
    
  }
  
}

# function for go for it WP
get_go_wp <- function(df) {
  
  # stuff in the model
  data <- df %>%
    select(
      down,    ydstogo,     yardline_100,  era3,     era4,     outdoors, 
      retractable,  dome,    posteam_spread, total_line,  posteam_total 
    )
  
  # if a td is scored, get go for 1 and go for 2 WP
  td_probs <- get_2pt_wp(
    df %>% mutate(
      # situation: team scored 6 points and 6 fewer seconds remain
      score_differential = score_differential + 6,
      half_seconds_remaining = max(half_seconds_remaining - 6, 0),
      game_seconds_remaining = max(game_seconds_remaining - 6, 0)
    )
  )
  
  # assume that team does smart thing (lol)
  td_prob <- max(td_probs$`WP kick`, td_probs$`WP 2pt`)
  
  # get model output from situation
  preds <- stats::predict(
    fd_model,
    as.matrix(data)
  )  %>%
    tibble::as_tibble() %>%
    dplyr::rename(prob = "value") %>%
    bind_cols(df[rep(1, 76), ]) %>%
    mutate(
      gain = -10:65,
      # if predicted gain is more than possible, call it a TD
      gain = if_else(gain > yardline_100, as.integer(yardline_100), as.integer(gain))
    ) %>%
    
    # this step is to combine all the TD probs into one (for gains longer than possible)
    group_by(gain) %>%
    mutate(prob = sum(prob)) %>%
    dplyr::slice(1) %>%
    ungroup() %>%
    
    # update situation based on play result
    mutate(
      yardline_100 = yardline_100 - gain,
      # for figuring out if it was a td later
      final_yardline = yardline_100,
      posteam_timeouts_pre = posteam_timeouts_remaining,
      defeam_timeouts_pre = defteam_timeouts_remaining,
      turnover = dplyr::if_else(gain < ydstogo, as.integer(1), as.integer(0)),
      down = 1,
      
      # # special case for turnover where other team gets ball
      # # note: touchdowns are dealt with separately in the 2pt function to start this function
      
      # flip yardline_100 for turnovers
      yardline_100 = dplyr::if_else(turnover == 1, as.integer(100 - yardline_100), as.integer(yardline_100)),
      
      # turnover: flip timeouts since other team gets ball
      posteam_timeouts_remaining = dplyr::if_else(turnover == 1 | yardline_100 == 0,
                                                  defeam_timeouts_pre,
                                                  posteam_timeouts_pre),
      defteam_timeouts_remaining = dplyr::if_else(turnover == 1 | yardline_100 == 0,
                                                  posteam_timeouts_pre,
                                                  defeam_timeouts_pre),
      
      # swap score diff if turnover on downs
      score_differential = if_else(turnover == 1, -score_differential, score_differential),
      
      # run off 6 seconds
      half_seconds_remaining = half_seconds_remaining - 6,
      game_seconds_remaining = game_seconds_remaining - 6,

      # additional runoff after successful non-td conversion (entered from user input)
      half_seconds_remaining = if_else(turnover == 0 & df$yardline_100 > gain, half_seconds_remaining - df$runoff, half_seconds_remaining),
      game_seconds_remaining = if_else(turnover == 0 & df$yardline_100 > gain, game_seconds_remaining - df$runoff, game_seconds_remaining),
      
      # after all that, make sure these aren't negative
      half_seconds_remaining = max(half_seconds_remaining, 0),
      game_seconds_remaining = max(game_seconds_remaining, 0),
      
      # flip receive_2h_ko var if turnover
      receive_2h_ko = case_when(
        qtr <= 2 & receive_2h_ko == 0 & (yardline_100 == 0 | turnover == 1) ~ 1,
        qtr <= 2 & receive_2h_ko == 1 & (yardline_100 == 0 | turnover == 1) ~ 0,
        TRUE ~ receive_2h_ko
      ),
      
      # switch posteam if turnover
      posteam = case_when(
        home_team == posteam & turnover == 1 ~ away_team, 
        away_team == posteam & turnover == 1 ~ home_team,
        TRUE ~ posteam
      ),
      
      # if now goal to go, use yardline for yards to go, otherwise it's 1st and 10 either way
      ydstogo = dplyr::if_else(yardline_100 < 10, as.integer(yardline_100), as.integer(10))
      
    ) %>%
    flip_half() %>%
    nflfastR::calculate_win_probability() %>%
    mutate(
      # flip WP for possession change (turnover)
      vegas_wp = if_else(posteam != df$posteam, 1 - vegas_wp, vegas_wp),
      # fill in end of game situation when team can kneel out clock after successful conversion
      vegas_wp = case_when(
        score_differential > 0 & turnover == 0 & df$yardline_100 > gain & game_seconds_remaining < 120 & defteam_timeouts_remaining == 0 ~ 1,
        score_differential > 0 & turnover == 0 & df$yardline_100 > gain & game_seconds_remaining < 80 & defteam_timeouts_remaining == 1 ~ 1,
        score_differential > 0 & turnover == 0 & df$yardline_100 > gain & game_seconds_remaining < 40 & defteam_timeouts_remaining == 2 ~ 1,
        TRUE ~ vegas_wp
      ),
      # fill in end of game situation when other team can kneel out clock after failed attempt
      vegas_wp = case_when(
        score_differential > 0 & turnover == 1 & game_seconds_remaining < 120 & defteam_timeouts_remaining == 0 ~ 0,
        score_differential > 0 & turnover == 1 & game_seconds_remaining < 80 & defteam_timeouts_remaining == 1 ~ 0,
        score_differential > 0 & turnover == 1 & game_seconds_remaining < 40 & defteam_timeouts_remaining == 2 ~ 0,
        TRUE ~ vegas_wp
      ),
      
      # if a team scores a touchdown, give them the td_prob generated above
      vegas_wp = if_else(final_yardline == 0, td_prob, vegas_wp)
    ) %>%
    mutate(wt_wp = prob * vegas_wp) 
  
  # for debugging shiny app
  # global_df <<- preds
  
  # gather the probabilities
  report <- preds %>%
    mutate(fd = if_else(gain < df$ydstogo, 0, 1)) %>%
    group_by(fd) %>%
    mutate(fd_pct = sum(prob), 
           new_prob = prob / fd_pct,
           wt_wp = new_prob * vegas_wp
    ) %>%
    summarize(
      pct = sum(prob),
      wp = sum(wt_wp)
    )
  
  first_down_prob <- report %>% filter(fd == 1) %>% pull(pct)
  wp_fail <- report %>% filter(fd == 0) %>% pull(wp)
  wp_succeed <- report %>% filter(fd == 1) %>% pull(wp)
  wp_go <- preds %>% summarize(wp = sum(wt_wp)) %>% pull(wp)
  
  # return for table
  results <- list(
    wp_go,
    first_down_prob,
    wp_fail,
    wp_succeed
    
  )
  
}


# get the numbers that go into the table
# this is a separate function in case one wants the actual numbers
make_table_data <- function(current_situation, punt_df) {
  
  # get punt wp numbers
  x <- get_punt_wp(current_situation, punt_df)
  
  # get fg wp numbers
  y <- get_fg_wp(current_situation)
  
  # get go wp numbers
  z <- get_go_wp(current_situation)
  
  go <- tibble::tibble(
    "choice_prob" = z[[1]],
    "choice" = "Go for it",
    "success_prob" = z[[2]],
    "fail_wp" = z[[3]],
    "success_wp" = z[[4]]
  ) %>%
    select(choice, choice_prob, success_prob, fail_wp, success_wp)
  
  fg <- tibble::tibble(
    "choice_prob" = y[[1]],
    "choice" = "Field goal attempt",
    "success_prob" = y[[2]],
    "fail_wp" = y[[3]],
    "success_wp" = y[[4]]
  ) %>%
    select(choice, choice_prob, success_prob, fail_wp, success_wp)
  
  punt <- tibble::tibble(
    "choice_prob" = if_else(is.na(x), NA_real_, x),
    "choice" = "Punt",
    "success_prob" = NA_real_,
    "fail_wp" = NA_real_,
    "success_wp" = NA_real_
  ) %>%
    select(choice, choice_prob, success_prob, fail_wp, success_wp)
  
  for_return <- bind_rows(
    go, fg, punt
  ) %>%
    mutate(
      choice_prob = 100 * choice_prob,
      success_prob = 100 * success_prob,
      fail_wp = 100 * fail_wp,
      success_wp = 100 * success_wp
    )
  
  # more debugging
  # global_data <<- for_return
  
  return(for_return)
}

# make the actual table given the numbers
make_table <- function(df, current_situation) {

  df %>%
    arrange(-choice_prob) %>%
    gt() %>%
    cols_label(
      choice = "",
      choice_prob = "Win %",
      success_prob = "Success %",
      success_wp = "Succeed",
      fail_wp = "Fail"
    ) %>%
    tab_style(
      style = cell_text(color = "black", weight = "bold"),
      locations = list(
        cells_row_groups(),
        cells_column_labels(everything())
      )
    ) %>% 
    tab_options(
      row_group.border.top.width = px(3),
      row_group.border.top.color = "black",
      row_group.border.bottom.color = "black",
      table_body.hlines.color = "white",
      table.border.top.color = "black",
      table.border.top.width = px(1),
      table.border.bottom.color = "white",
      table.border.bottom.width = px(1),
      column_labels.border.bottom.color = "black",
      column_labels.border.bottom.width = px(2)
    ) %>%
    fmt_number(
      columns = vars(choice_prob, success_prob, success_wp, fail_wp), decimals = 0
    ) %>%
    tab_source_note(md("**Please cite**: Ben Baldwin's fourth down model"
    )) %>%
    tab_style(
      style = list(
        cell_text(color = "red", weight = "bold")
      ),
      locations = cells_body(
        columns = vars(choice_prob)
      )
    )  %>% 
    tab_style(
      style = list(
        cell_text(weight = "bold")
      ),
      locations = cells_body(
        columns = vars(choice)
      )
    )  %>% 
    tab_spanner(label = "Win % if",
                columns = 4:5) %>%
    cols_align(
      columns = 2:5,
      align = "center"
    ) %>% 
    tab_footnote(
      footnote = "Expected win % for a given decision",
      locations = cells_column_labels(2)
    ) %>% 
    tab_footnote(
      footnote = "Likelihood of converting on 4th down or of making field goal",
      locations = cells_column_labels(3)
    )  %>%
    tab_header(
      title = md(glue::glue("{case_when(current_situation$score_differential < 0 ~ 'Down', current_situation$score_differential == 0 ~ 'Tied', current_situation$score_differential > 0 ~ 'Up')} {ifelse(current_situation$score_differential == 0, 'up', abs(current_situation$score_differential))}, 4th & {current_situation$ydstogo}, {current_situation$yardline_100} yards from opponent end zone")),
      subtitle = md(glue::glue("Qtr {current_situation$qtr}, {hms::hms(current_situation$time) %>% substr(4, 8)}"))
    )
  
}
  

# function to get WPs PAT decisions
get_2pt_wp <- function(df) {
  
  # stuff in the 2pt model
  data <- df %>%
    mutate(era2 = 0) %>%
    select(
      era2,  era3,     era4,     outdoors, 
      retractable,  dome,    posteam_spread, total_line,  posteam_total 
    )
  
  # get probability of converting 2pt attempt from model
  make_prob <- stats::predict(
    two_pt_model,
    as.matrix(data)
  )  %>%
    tibble::as_tibble() %>%
    dplyr::rename(prob = "value") %>%
    dplyr::pull(prob)
  
  # probability of making PAT
  xp_prob <- as.numeric(mgcv::predict.bam(fg_model, newdata = df %>% mutate(yardline_100 = 15), type="response"))
  
  wps <- 1 - tibble::tibble(
    score_differential = c(-df$score_differential, -df$score_differential - 1, -df$score_differential - 2),
    yardline_100 = 75,
    posteam_timeouts_remaining = df$defteam_timeouts_remaining,
    defteam_timeouts_remaining = df$posteam_timeouts_remaining,
    down = 1,
    ydstogo = 10,
    half_seconds_remaining = df$half_seconds_remaining,
    game_seconds_remaining = df$game_seconds_remaining,
    receive_2h_ko = case_when(
      df$qtr <= 2 & df$receive_2h_ko == 0 ~ 1,
      df$qtr <= 2 & df$receive_2h_ko == 1 ~ 0,
      TRUE ~ df$receive_2h_ko
    ),
    # switch posteam
    posteam = if_else(df$home_team == df$posteam, df$away_team, df$home_team),
    season = df$season,
    home_team = df$home_team,
    away_team = df$away_team,
    roof = df$roof,
    spread_line = df$spread_line,
    home_opening_kickoff = df$home_opening_kickoff,
    qtr = df$qtr,
  ) %>%
    # for end of half situation
    flip_half() %>%
    nflfastR::calculate_win_probability() %>%
    # for other side of half
    mutate(vegas_wp = if_else(posteam == df$posteam, 1 - vegas_wp, vegas_wp)) %>%
    pull(vegas_wp)
  
  # xp wp
  xp_wp <- xp_prob * wps[[2]] + (1 - xp_prob) * wps[[1]]
  
  # 2pt wp
  two_pt_wp <- make_prob * wps[[3]] + (1 - make_prob) * wps[[1]]
  
  # bind up the probs to return for table
  results <- list(two_pt_wp, xp_wp, make_prob, xp_prob, wps)
  names(results) <- c("WP 2pt", "WP kick", "Conv %", "PAT %", "WPs")
  
  return(results)
}



# get the numbers that go into the table
# this is a separate function in case one wants the actual numbers
make_2pt_table_data <- function(current_situation) {
  
  # get punt wp numbers
  z <- get_2pt_wp(current_situation)
  
  go <- tibble::tibble(
    "choice_prob" = z[[1]],
    "choice" = "Go for 2",
    "success_prob" = z[[3]],
    "fail_wp" = z[[5]][[1]],
    "success_wp" = z[[5]][[3]]
  ) %>%
    select(choice, choice_prob, success_prob, fail_wp, success_wp)
  
  pat <- tibble::tibble(
    "choice_prob" = z[[2]],
    "choice" = "Kick XP",
    "success_prob" = z[[4]],
    "fail_wp" = z[[5]][[1]],
    "success_wp" = z[[5]][[2]]
  ) %>%
    select(choice, choice_prob, success_prob, fail_wp, success_wp)
  
  
  for_return <- bind_rows(
    go, pat
  ) %>%
    mutate(
      choice_prob = 100 * choice_prob,
      success_prob = 100 * success_prob,
      fail_wp = 100 * fail_wp,
      success_wp = 100 * success_wp
    )
  
  # more debugging
  # global_data <<- for_return
  
  return(for_return)
}



# make the actual table given the numbers
make_table_2pt <- function(df, current_situation) {
  
  df %>%
    arrange(-choice_prob) %>%
    gt() %>%
    cols_label(
      choice = "",
      choice_prob = "Win %",
      success_prob = "Success %",
      success_wp = "Succeed",
      fail_wp = "Fail"
    ) %>%
    tab_style(
      style = cell_text(color = "black", weight = "bold"),
      locations = list(
        cells_row_groups(),
        cells_column_labels(everything())
      )
    ) %>% 
    tab_options(
      row_group.border.top.width = px(3),
      row_group.border.top.color = "black",
      row_group.border.bottom.color = "black",
      table_body.hlines.color = "white",
      table.border.top.color = "black",
      table.border.top.width = px(1),
      table.border.bottom.color = "white",
      table.border.bottom.width = px(1),
      column_labels.border.bottom.color = "black",
      column_labels.border.bottom.width = px(2)
    ) %>%
    fmt_number(
      columns = vars(choice_prob, success_prob, success_wp, fail_wp), decimals = 0
    ) %>%
    tab_source_note(md("**Please cite**: Ben Baldwin's 2-point down model"
    )) %>%
    tab_style(
      style = list(
        cell_text(color = "red", weight = "bold")
      ),
      locations = cells_body(
        columns = vars(choice_prob)
      )
    )  %>% 
    tab_style(
      style = list(
        cell_text(weight = "bold")
      ),
      locations = cells_body(
        columns = vars(choice)
      )
    )  %>% 
    tab_spanner(label = "Win % if",
                columns = 4:5) %>%
    cols_align(
      columns = 2:5,
      align = "center"
    ) %>% 
    tab_footnote(
      footnote = "Expected win % for a given decision",
      locations = cells_column_labels(2)
    ) %>% 
    tab_footnote(
      footnote = "Likelihood of converting 2 point attempt or PAT",
      locations = cells_column_labels(3)
    )  %>%
    tab_header(
      title = md(glue::glue("{case_when(current_situation$score_differential < 0 ~ 'Down', current_situation$score_differential == 0 ~ 'Tied', current_situation$score_differential > 0 ~ 'Up')} {ifelse(current_situation$score_differential == 0, 'up', abs(current_situation$score_differential))}, Qtr {current_situation$qtr}, {hms::hms(current_situation$time) %>% substr(4, 8)}"))
    )
  
}


