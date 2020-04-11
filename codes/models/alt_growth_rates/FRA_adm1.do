// FRA | ADM1 

clear all
//-----------------------setup

// import end of sample cut-off 
import delim using codes/data/cutoff_dates.csv, clear 
keep if tag == "default"
local end_sample = end_date[1]

// load data
insheet using data/processed/adm1/FRA_processed.csv, clear 

cap set scheme covid19_fig3 // optional scheme for graphs
 
// set up time variables
gen t = date(date, "YMD")
lab var t "date"
gen dow = dow(t)
gen month = month(t)
gen year = year(t)
gen day = day(t)

// set up panel
xtset adm1_id t

// quality control
drop if cum_confirmed_cases < 10  
keep if t >= date("20200228","YMD") // Non stable growth before that point & missing data, only one region with +10 but no growth
keep if t <= date("`end_sample'","YMD") // to match other country end dates


// flag which admin unit has longest series
tab adm1_name if cum_confirmed_cases!=., sort 
bysort adm1_name: egen adm1_obs_ct = count(cum_confirmed_cases)

// if multiple admin units have max number of days w/ confirmed cases, 
// choose the admin unit with the max number of confirmed cases 
bysort adm1_name: egen adm1_max_cases = max(cum_confirmed_cases)
egen max_obs_ct = max(adm1_obs_ct)
bysort adm1_obs_ct: egen max_obs_ct_max_cases = max(adm1_max_cases) 

gen longest_series = adm1_obs_ct==max_obs_ct & adm1_max_cases==max_obs_ct_max_cases
drop adm1_obs_ct adm1_max_cases max_obs_ct max_obs_ct_max_cases

sort adm1_id t
tab adm1_name if longest_series==1 & cum_confirmed_cases!=.


// construct dep vars
lab var cum_confirmed_cases "cumulative confirmed cases"

gen l_cum_confirmed_cases = log(cum_confirmed_cases)
lab var l_cum_confirmed_cases "log(cum_confirmed_cases)"

gen D_l_cum_confirmed_cases = D.l_cum_confirmed_cases 
lab var D_l_cum_confirmed_cases "change in log(cum. confirmed cases)"

// quality control: cannot have negative changes in cumulative values
replace D_l_cum_confirmed_cases = . if D_l_cum_confirmed_cases < 0 //0 negative changes for France


//------------------diagnostic

// diagnostic plot of trends with sample avg as line
reg D_l_cum_confirmed_cases
gen sample_avg = _b[_cons] if e(sample)
replace sample_avg = . if longest_series==1

reg D_l_cum_confirmed_cases i.t
predict day_avg if longest_series==1 & e(sample)
lab var day_avg "Observed avg. change in log cases"

*tw (sc D_l_cum_confirmed_cases t, msize(tiny))(line sample_avg t)(sc day_avg t)


//------------------testing regime changes

g testing_regime_13mar2020 = t == mdy(3,15,2020) // start of stade 3, none systematic testing
lab var testing_regime_13mar2020 "Testing regime change on Mar 15, 2020"


//------------------generate policy packages

gen national_lockdown = (business_closure + home_isolation) / 2 // big national lockdown policy
lab var national_lockdown "National lockdown"

gen no_gathering_5000 = no_gathering_size <= 5000
gen no_gathering_1000 = no_gathering_size <= 1000
gen no_gathering_100 = no_gathering_size <= 100

gen pck_social_distance = (no_gathering_1000 + no_gathering_100 + event_cancel + no_gathering_inside + social_distance) / 5
lab var pck_social_distance "Social distance"

lab var school_closure "School closure"

// gen policy_ct = pck_social_distance + school_closure + national_lockdown
// sum policy_ct

//------------------main estimates

// output data used for reg
outsheet using "models/reg_data/FRA_reg_data.csv", comma replace

// main regression model
reghdfe D_l_cum_confirmed_cases pck_social_distance school_closure national_lockdown ///
 testing_regime_*, absorb(i.adm1_id i.dow, savefe) cluster(t) resid 
 
outreg2 using "results/tables/FRA_estimates_table", sideway noparen nodepvar word replace label ///
 addtext(Region FE, "YES", Day-of-Week FE, "YES") title(France, "Dependent variable: Growth rate of cumulative confirmed cases (\u0916?log per day\'29") ///
 ctitle("Coefficient"; "Robust Std. Error") nonotes addnote("*** p<0.01, ** p<0.05, * p<0.1" "" /// 
 "\'22National lockdown\'22 policies include business closures and home isolation.")
cap erase "results/tables/FRA_estimates_table.txt"

// saving coefs
tempfile results_file
postfile results str18 adm0 str18 policy beta se using `results_file', replace
foreach var in "national_lockdown" "school_closure" "pck_social_distance" {
	post results ("FRA") ("`var'") (round(_b[`var'], 0.001)) (round(_se[`var'], 0.001)) 
}

//------------- checking error structure (make fig for appendix)

predict e if e(sample), resid

hist e, bin(30) tit(France) lcolor(white) fcolor(navy) xsize(5) name(hist_fra, replace)

qnorm e, mcolor(black) rlopts(lcolor(black)) xsize(5) name(qn_fra, replace)

graph combine hist_fra qn_fra, rows(1) xsize(10) saving(results/figures/appendix/error_dist/error_fra.gph, replace)
graph drop hist_fra qn_fra

outsheet e using "results/source_data/ExtendedDataFigure1_FRA_e.csv" if e(sample), comma replace


// ------------- generating predicted values and counterfactual predictions based on treatment

// predicted "actual" outcomes with real policies
*predict y_actual if e(sample)
predictnl y_actual = xb() + __hdfe1__ + __hdfe2__ if e(sample), ci(lb_y_actual ub_y_actual)
lab var y_actual "predicted growth with actual policy"

// estimating magnitude of treatment effects for each obs
gen treatment = pck_social_distance * _b[pck_social_distance] + ///
school_closure * _b[school_closure] + ///
national_lockdown* _b[national_lockdown] ///
if e(sample)

// predicting counterfactual growth for each obs
predictnl y_counter =  testing_regime_13mar2020 * _b[testing_regime_13mar2020] + ///
_b[_cons] + __hdfe1__ + __hdfe2__ if e(sample), ci(lb_counter ub_counter)

// effect of all policies combined (FOR FIG2)
lincom national_lockdown + school_closure + pck_social_distance 
post results ("FRA") ("comb. policy") (round(r(estimate), 0.001)) (round(r(se), 0.001)) 

local comb_policy = round(r(estimate), 0.001)
local subtitle = "Combined effect = " + string(`comb_policy') // for coefplot

// get ATE
preserve
	keep if e(sample) == 1
	collapse  D_l_cum_confirmed_cases school_closure pck_social_distance national_lockdown
	predictnl ATE = school_closure * _b[school_closure] + ///
	pck_social_distance * _b[pck_social_distance] + ///
	national_lockdown* _b[national_lockdown], ci(LB UB) se(sd) p(pval)
	g adm0 = "FRA"
	outsheet * using "models/FRA_ATE.csv", comma replace 
restore

// quality control: cannot have negative growth in cumulative cases
// fix so there are no negative growth rates in error bars
foreach var of varlist y_actual y_counter lb_y_actual ub_y_actual lb_counter ub_counter{
	replace `var' = 0 if `var'<0 & `var'!=.
}

// the mean here is the avg "biological" rate of initial spread (FOR FIG2)
sum y_counter
post results ("FRA") ("no_policy rate") (round(r(mean), 0.001)) (round(r(sd), 0.001)) 

local no_policy = round(r(mean), 0.001)
local subtitle2 = "`subtitle' ; No policy = " + string(`no_policy') // for coefplot

// looking at different policies (similar to FIG2)
coefplot, keep(pck_social_distance school_closure national_lockdown) ///
tit("FRA: policy packages") subtitle("`subtitle2'") ///
caption("Social distance = (no_gath_1000 + no_gath_100 + event_cancel +" " no_gathering_inside + social_distance) / 5" ///
"National lockdown = (business_closure + home_isolation) / 2", span) ///
xline(0) name(FRA_policy, replace) 


// export coefficients (FOR FIG2)
postclose results
preserve
	use `results_file', clear
	outsheet * using "results/source_data/Figure2_FRA_coefs.csv", comma replace
restore

// export predicted counterfactual growth rate
preserve
	keep if e(sample) == 1
	keep y_counter
	g adm0 = "FRA"
	outsheet * using "models/FRA_preds.csv", comma replace
restore

// the mean average growth rate suppression delivered by existing policy (FOR TEXT)
sum treatment

// computing daily avgs in sample, store with a single panel unit (longest time series)
reg y_actual i.t
predict m_y_actual if longest_series==1

reg y_counter i.t
predict m_y_counter if longest_series==1


// add random noise to time var to create jittered error bars
set seed 1234
g t_random = t + rnormal(0,1)/10
g t_random2 = t + rnormal(0,1)/10

// Graph of predicted growth rates (FOR FIG3)

// fixed x-axis across countries
tw (rspike ub_y_actual lb_y_actual t_random, lwidth(vthin) color(blue*.5)) ///
(rspike ub_counter lb_counter t_random2, lwidth(vthin) color(red*.5)) ///
|| (scatter y_actual t_random, msize(tiny) color(blue*.5) ) ///
(scatter y_counter t_random2, msize(tiny) color(red*.5)) ///
(connect m_y_actual t, color(blue) m(square) lpattern(solid)) ///
(connect m_y_counter t, color(red) lpattern(dash) m(Oh)) ///
(sc day_avg t, color(black)) ///
if e(sample), ///
title(France, ring(0)) ytit("Growth rate of" "cumulative cases" "({&Delta}log per day)") ///
xscale(range(21930(10)22011)) xlabel(21930(10)22011, nolabels tlwidth(medthick)) tmtick(##10) ///
yscale(r(0(.2).8)) ylabel(0(.2).8) plotregion(m(b=0)) ///
saving(results/figures/fig3/raw/FRA_adm1_conf_cases_growth_rates_fixedx.gph, replace)

egen miss_ct = rowmiss(m_y_actual y_actual lb_y_actual ub_y_actual m_y_counter y_counter lb_counter ub_counter)
outsheet t m_y_actual y_actual lb_y_actual ub_y_actual m_y_counter y_counter lb_counter ub_counter ///
using "results/source_data/Figure3_FRA_data.csv" if miss_ct<8, comma replace
drop miss_ct

// tw (rspike ub_y_actual lb_y_actual t_random, lwidth(vthin) color(blue*.5)) ///
// (rspike ub_counter lb_counter t_random2, lwidth(vthin) color(red*.5)) ///
// || (scatter y_actual t_random, msize(tiny) color(blue*.5) ) ///
// (scatter y_counter t_random2, msize(tiny) color(red*.5)) ///
// (connect m_y_actual t, color(blue) m(square) lpattern(solid)) ///
// (connect m_y_counter t, color(red) lpattern(dash) m(Oh)) ///
// (sc day_avg t, color(black)) ///
// if e(sample), ///
// title(France, ring(0)) ytit("Growth rate of" "cumulative cases" "({&Delta}log per day)") ///
// xscale(range(21970(10)22000)) xlabel(21970(10)22000, format(%tdMon_DD) tlwidth(medthick)) tmtick(##10) ///
// yscale(r(0(.2).8)) ylabel(0(.2).8) plotregion(m(b=0))


//-------------------------------Cross-validation

tempfile results_file_crossV
postfile results str18 adm0 str18 sample str18 policy beta se using `results_file_crossV', replace

*Resave main effect
reghdfe D_l_cum_confirmed_cases pck_social_distance school_closure ///
national_lockdown testing_regime_*, absorb(i.adm1_id i.dow, savefe) cluster(t) resid 

foreach var in "national_lockdown" "school_closure" "pck_social_distance" {
	post results ("FRA") ("full_sample") ("`var'") (round(_b[`var'], 0.001)) (round(_se[`var'], 0.001)) 
}
lincom national_lockdown + school_closure + pck_social_distance
post results ("FRA") ("full_sample") ("comb. policy") (round(r(estimate), 0.001)) (round(r(se), 0.001)) 

*Estimate same model leaving out one region
levelsof adm1_name, local(state_list)
foreach adm in `state_list' {
	reghdfe D_l_cum_confirmed_cases national_lockdown school_closure ///
	pck_social_distance testing_regime_* if adm1_name != "`adm'" , absorb(i.adm1_id i.dow, savefe) cluster(t) resid 
	foreach var in "national_lockdown" "school_closure" "pck_social_distance" {
		post results ("FRA") ("`adm'") ("`var'") (round(_b[`var'], 0.001)) (round(_se[`var'], 0.001)) 
	}
	lincom national_lockdown + school_closure + pck_social_distance
	post results ("FRA") ("`adm'") ("comb. policy") (round(r(estimate), 0.001)) (round(r(se), 0.001)) 
}
postclose results

preserve
	set scheme s1color
	use `results_file_crossV', clear
	egen i = group(policy)
	tw scatter i beta if sample != "GrandEst", xline(0,lc(black) lp(dash)) mc(black*.5)  ///
	|| scatter i beta if sample == "full_sample", mc(red) ///
	|| scatter i beta if sample == "GrandEst", mc(green) m(Oh) ///
	yscale(range(0(1)6)) ylabel(1 "combined effect" ///
	2 "National lockdown" ///
	3 "School closure" ///
	4 "Social distance", angle(0)) ytitle("") xtitle("Estimated effect on daily growth rate", height(5)) ///
	xscale(range(-0.4(0.1)0.1)) xlabel(#5) xsize(7) ///
	legend(order(2 1 3) lab(2 "Full sample") lab(1 "Leaving one region out") ///
	lab(3 "w/o Grand Est") region(lstyle(none)) pos(11) ring(0)) 
	graph export results/figures/appendix/cross_valid/FRA.pdf, replace
	graph export results/figures/appendix/cross_valid/FRA.png, replace	
	outsheet * using "results/source_data/extended_cross_validation_FRA.csv", replace
restore


//-------------------------------FIXED LAG

preserve
	reghdfe D_l_cum_confirmed_cases pck_social_distance school_closure ///
	national_lockdown testing_regime_*, absorb(i.adm1_id i.dow, savefe) cluster(t) resid 
	 
	coefplot, keep(pck_social_distance school_closure national_lockdown) gen(L0_) title(main model) xline(0) 
	foreach lags of num 1/5 { 
		quietly {
		foreach var in pck_social_distance school_closure national_lockdown{
			g `var'_copy = `var'
			g `var'_fixelag = L`lags'.`var'
			replace `var' = `var'_fixelag
			
		}
		drop *_fixelag 

		reghdfe D_l_cum_confirmed_cases pck_social_distance school_closure ///
		national_lockdown testing_regime_*, absorb(i.adm1_id i.dow, savefe) cluster(t) resid
		coefplot, keep(pck_social_distance school_closure national_lockdown) ///
		gen(L`lags'_) title (with fixed lag (4 days)) xline(0)
		replace L`lags'_at = L`lags'_at - 0.1 *`lags'
		
		foreach var in pck_social_distance school_closure national_lockdown{
			replace `var' = `var'_copy
			drop `var'_copy
		}
		}
	}


	set scheme s1color
	tw rspike L0_ll1 L0_ul1 L0_at , hor xline(0) lc(black) lw(thin) ///
	|| scatter  L0_at L0_b, mc(black) ///
	|| rspike L1_ll1 L1_ul1 L1_at , hor xline(0) lc(black*.9) lw(thin) ///
	|| scatter  L1_at L1_b, mc(black*.9) ///
	|| rspike L2_ll1 L2_ul1 L2_at , hor xline(0) lc(black*.7) lw(thin) ///
	|| scatter  L2_at L2_b, mc(black*.7) ///
	|| rspike L3_ll1 L3_ul1 L3_at , hor xline(0) lc(black*.5) lw(thin) ///
	|| scatter  L3_at L3_b, mc(black*.5) ///
	|| rspike L4_ll1 L4_ul1 L4_at , hor xline(0) lc(black*.3) lw(thin) ///
	|| scatter  L4_at L4_b, mc(black*.3) ///
	|| rspike L5_ll1 L5_ul1 L5_at , hor xline(0) lc(black*.1) lw(thin) ///
	|| scatter  L5_at L5_b, mc(black*.1) ///	
	ylabel(1 "Social distance" ///
	2 "School closure" ///
	3 "National Lockdown", angle(0)) ///
	ytitle("") title("France comparing Fixed Lags models") ///
	legend(order(2 4 6 8 10 12) lab(2 "L0") lab(4 "L1") lab(6 "L2") lab(8 "L3") ///
	lab(10 "L4") lab(12 "L5") rows(1) region(lstyle(none)))
	graph export results/figures/appendix/fixed_lag/FRA.pdf, replace
	graph export results/figures/appendix/fixed_lag/FRA.png, replace
	drop if L0_b == .
	keep *_at *_ll1 *_ul1 *_b
	egen policy = seq()
	reshape long L0_ L1_ L2_ L3_ L4_ L5_, i(policy) j(temp) string
	rename *_ *
	reshape long L, i(temp policy) j(val)
	tostring policy, replace
	replace policy = "Social distance" if policy == "1"
	replace policy = "School closure" if policy == "2"
	replace policy = "National lockdown" if policy == "3"
	rename val lag
	reshape wide L, i(lag policy) j(temp) string
	sort Lat
	rename (Lat Lb Lll1 Lul1) (position beta lower_CI upper_CI)
	outsheet * using "results/source_data/extended_fixed_lag_FRA.csv", replace
restore
