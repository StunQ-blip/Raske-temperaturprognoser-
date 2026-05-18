%% ============================================================
% REGRESJONSANALYSE FRA LAGRET DATASETT — FYRINGSSESONG
%
% Selvstendig kode som laster datasettet fyringto.m har lagret
% (etter en simuleringskjøring) og kjører regresjonsvariantene
% V1–V4. Skriver samme output-filer som fyringto skriver, slik at
% untitled.m (plotting) kan kjøres etterpå uten endring.
%
% Trenger ingen simuleringskode — leser kun én tabell fra disk.
%
% Varianter:
%   V1 = re-trening hver 7. dag (vindu = 7 dager), daglig re-init
%   V2 = daglig re-trening, rullende 7-dagers vindu, daglig re-init
%   V3 = daglig re-trening, vindu = 24 timer, daglig re-init  (BASELINE)
%   V4 = re-trening hver 12. time (vindu = 12 timer), daglig re-init
%
% Regresjonsmodellen:
%   T̂_ut(k+1) = β₀ + β₁·T̂_ut(k) + β₂·PVP(k) + β₃·ΔPVP(k)
%% ============================================================

clc
clear
close all

%% ------------------------------------------------------------
% BRUKERINNSTILLINGER  (hardkoda — juster etter behov)
% -------------------------------------------------------------

% --- Plassering av lagret datasett ----------------------------
resultFolder    = 'C:\Users\rynsk\OneDrive - OsloMet\bachelor 2026\Simuleringer MSI dragon 10';
runName         = 'simulering_fyringssesong';
datasetFileName = 'dataset_for_regression.xlsx';

% --- Fysiske konstanter (må matche fyringtos cfg/flow/Th) -----
cf             = 1151 * 3600;    % volumetrisk varmekapasitet · 3600 = cfg.cf
flow_const_lps = 0.40;           % konstant fluidstrøm [l/s]
Th             = 900;            % tidssteg [s] = 15 min

% --- Regresjonsoppsett ----------------------------------------
trainDaysInit   = 1:7;           % initialtrening på dag 1–7
validDays       = 8:212;         % valideringsperiode (hele fyringssesongen)
retrainInterval = 7;             % V1: dager mellom hver re-trening
windowDays_v2   = 7;             % V2: rullende vindu i dager
stepsHalfDay    = 48;            % V4: 12 timer = 48 tidssteg

predictorVars   = {'Tout_k','PVP_k','dPVP_k'};
targetNameTout  = 'Tout_next_C';

% --- Figuroppsett ---------------------------------------------
% Startdato for datasettet (brukes til å plassere helgeskygge).
simStartDate  = datetime(2018,10,1);   % fyringssesongen starter her

% Antall dager som skal vises/analyseres fra starten av datasettet.
% Bruk Inf for å analysere/plotte hele datasettet.
daysToAnalyse = Inf;

%% ------------------------------------------------------------
% LAST DATASETT FRA DISK
% -------------------------------------------------------------
runRoot     = fullfile(resultFolder, runName);
datasetFile = fullfile(runRoot, datasetFileName);

if ~isfile(datasetFile)
    error(['Fant ikke datasettfil:\n  %s\n\n', ...
           'Kjør fyringto.m først (med save-blokken som lagrer ', ...
           '''dataset_for_regression.xlsx''), eller juster ', ...
           'resultFolder/runName øverst i denne fila.'], datasetFile);
end

fprintf('Laster datasett: %s\n', datasetFile);

% Leser Excel-arket. Kolonnenavnene beholdes som de er (Tout_k, PVP_k, ...)
% slik at koden under refererer til kolonner ved navn, ikke posisjon.
dataRows = readtable(datasetFile, 'VariableNamingRule', 'preserve');

% Sikre at kolonnenavn matcher det koden forventer (readtable kan ellers
% bytte ut tegn). De forventede navnene er gyldige identifikatorer, så
% dette er bare en robusthetssjekk.
requiredCols = {'DayID','StepIndex','Time_h_global', ...
                'Tin_k','Tout_k','DeltaT_k','PVP_k','dPVP_k', ...
                'PVP_next_W','Tin_next_C','Tout_next_C','DeltaT_next_C'};
missingCols = setdiff(requiredCols, dataRows.Properties.VariableNames);
if ~isempty(missingCols)
    error(['Excel-arket mangler nødvendige kolonner: %s\n', ...
           'Ikke gi nytt navn til, eller slett, kolonneoverskriftene.'], ...
           strjoin(missingCols, ', '));
end

fprintf('  %d rader i datasettet\n', height(dataRows));

%% ------------------------------------------------------------
% FORBERED VALIDERINGSDATA
% -------------------------------------------------------------
validTbl = dataRows(ismember(dataRows.DayID, validDays), :);
validTbl = sortrows(validTbl, {'DayID','StepIndex'});

nValid = height(validTbl);
dt_h   = Th / 3600;

Tout_true   = [validTbl.Tout_k(1);   validTbl.Tout_next_C];
Tin_true    = [validTbl.Tin_k(1);    validTbl.Tin_next_C];
DeltaT_true = [validTbl.DeltaT_k(1); validTbl.DeltaT_next_C];
PVP_series  = [validTbl.PVP_k(1);   validTbl.PVP_next_W];
time_h      = validTbl.Time_h_global(1) + (0:nValid)' * dt_h;

PVP_k_vec  = validTbl.PVP_k;
dPVP_k_vec = validTbl.dPVP_k;
flow_m3s   = flow_const_lps / 1000;

validDayIDs   = validTbl.DayID;
uniqueValDays = unique(validDayIDs);

%% ============================================================
% INITIELL TRENING PÅ DAG 1–7 (felles baseline for alle varianter)
% =============================================================
trainTbl_init = dataRows(ismember(dataRows.DayID, trainDaysInit), :);
mdl_init      = train_tout_model(trainTbl_init, predictorVars, targetNameTout);
c1            = mdl_init.fitlm.Coefficients.Estimate;

%% ============================================================
% VARIANT 1: RE-TRENING HVER 7. DAG, DAGLIG RE-INITIALISERING
% =============================================================
fprintf('\n=== VARIANT 1: Re-trening hver 7. dag, daglig re-initialisering ===\n');

Tout_hat_v1    = nan(nValid + 1, 1);
Tout_hat_v1(1) = validTbl.Tout_k(1);

c1_current     = c1;
trainStart_v1  = trainDaysInit(1);
trainEnd_v1    = trainDaysInit(end);
nextRetrain_v1 = validDays(1) + retrainInterval;

for dIdx = 1:numel(uniqueValDays)
    thisDay  = uniqueValDays(dIdx);
    dayMask  = find(validDayIDs == thisDay);
    kStart   = dayMask(1);

    if thisDay >= nextRetrain_v1
        trainEnd_v1   = thisDay - 1;
        trainStart_v1 = trainEnd_v1 - retrainInterval + 1;
        trainStart_v1 = max(trainStart_v1, 1);

        currentTrainTbl = dataRows( ...
            dataRows.DayID >= trainStart_v1 & dataRows.DayID <= trainEnd_v1, :);
        if height(currentTrainTbl) >= 10
            mdl_v1_win = train_tout_model(currentTrainTbl, predictorVars, targetNameTout);
            c1_current = mdl_v1_win.fitlm.Coefficients.Estimate;
        end
        nextRetrain_v1 = thisDay + retrainInterval;
        fprintf('  Re-trent dag %2d–%2d -> predikerer dag %2d\n', ...
            trainStart_v1, trainEnd_v1, thisDay);
    end

    Tout_hat_v1(kStart) = validTbl.Tout_k(kStart);

    for k = dayMask'
        Tout_hat_v1(k+1) = c1_current(1) + c1_current(2)*Tout_hat_v1(k) ...
                          + c1_current(3)*PVP_k_vec(k) + c1_current(4)*dPVP_k_vec(k);
    end
end

Tin_hat_v1    = Tout_hat_v1 + PVP_series ./ (cf * flow_m3s);
DeltaT_hat_v1 = Tout_hat_v1 - Tin_hat_v1;

RMSE_Tout_v1 = sqrt(mean((Tout_true(2:end) - Tout_hat_v1(2:end)).^2, 'omitnan'));
MAE_Tout_v1  = mean(abs(Tout_true(2:end) - Tout_hat_v1(2:end)), 'omitnan');

fprintf('  RMSE Tout: %.4f C  |  MAE Tout: %.4f C\n', ...
    RMSE_Tout_v1, MAE_Tout_v1);

%% ============================================================
% VARIANT 2: DAGLIG RE-TRENING, RULLENDE 7-DAGERS VINDU
% =============================================================
fprintf('\n=== VARIANT 2: Daglig re-trening, rullende 7-dagers vindu ===\n');

Tout_hat_v2    = nan(nValid + 1, 1);
Tout_hat_v2(1) = validTbl.Tout_k(1);

c2_current = c1;

for dIdx = 1:numel(uniqueValDays)
    thisDay  = uniqueValDays(dIdx);
    dayMask  = find(validDayIDs == thisDay);
    kStart   = dayMask(1);

    trainEnd_v2   = thisDay - 1;
    trainStart_v2 = trainEnd_v2 - windowDays_v2 + 1;
    trainStart_v2 = max(trainStart_v2, 1);

    currentTrainTbl = dataRows( ...
        dataRows.DayID >= trainStart_v2 & dataRows.DayID <= trainEnd_v2, :);
    if height(currentTrainTbl) >= 10
        mdl_v2_win = train_tout_model(currentTrainTbl, predictorVars, targetNameTout);
        c2_current = mdl_v2_win.fitlm.Coefficients.Estimate;
    end

    Tout_hat_v2(kStart) = validTbl.Tout_k(kStart);

    for k = dayMask'
        Tout_hat_v2(k+1) = c2_current(1) + c2_current(2)*Tout_hat_v2(k) ...
                          + c2_current(3)*PVP_k_vec(k) + c2_current(4)*dPVP_k_vec(k);
    end
end

Tin_hat_v2    = Tout_hat_v2 + PVP_series ./ (cf * flow_m3s);
DeltaT_hat_v2 = Tout_hat_v2 - Tin_hat_v2;

RMSE_Tout_v2 = sqrt(mean((Tout_true(2:end) - Tout_hat_v2(2:end)).^2, 'omitnan'));
MAE_Tout_v2  = mean(abs(Tout_true(2:end) - Tout_hat_v2(2:end)), 'omitnan');

fprintf('  RMSE Tout: %.4f C  |  MAE Tout: %.4f C\n', RMSE_Tout_v2, MAE_Tout_v2);

%% ============================================================
% VARIANT 3: RE-TRENING HVER DAG (VINDU = 24 TIMER), DAGLIG RE-INIT
% =============================================================
fprintf('\n=== VARIANT 3: Re-trening hver dag (vindu = 24 timer) ===\n');

Tout_hat_v3 = nan(nValid + 1, 1);

for dIdx = 1:numel(uniqueValDays)
    thisDay = uniqueValDays(dIdx);
    dayMask = find(validDayIDs == thisDay);
    kStart  = dayMask(1);

    globalStartTime = validTbl.Time_h_global(kStart);
    trainEndTime    = globalStartTime;
    trainStartTime  = trainEndTime - 24;

    trainMask_v3 = dataRows.Time_h_global >= trainStartTime & ...
                   dataRows.Time_h_global <  trainEndTime;
    trainTbl_v3  = dataRows(trainMask_v3, :);

    if height(trainTbl_v3) < 10
        c3 = c1;
    else
        mdl_v3_win = train_tout_model(trainTbl_v3, predictorVars, targetNameTout);
        c3 = mdl_v3_win.fitlm.Coefficients.Estimate;
    end

    Tout_hat_v3(kStart) = validTbl.Tout_k(kStart);

    for k = dayMask'
        Tout_hat_v3(k+1) = c3(1) + c3(2)*Tout_hat_v3(k) ...
                          + c3(3)*PVP_k_vec(k) + c3(4)*dPVP_k_vec(k);
    end
end

Tin_hat_v3    = Tout_hat_v3 + PVP_series ./ (cf * flow_m3s);
DeltaT_hat_v3 = Tout_hat_v3 - Tin_hat_v3;

RMSE_Tout_v3 = sqrt(mean((Tout_true(2:end) - Tout_hat_v3(2:end)).^2, 'omitnan'));
MAE_Tout_v3  = mean(abs(Tout_true(2:end) - Tout_hat_v3(2:end)), 'omitnan');

fprintf('  RMSE Tout: %.4f C  |  MAE Tout: %.4f C\n', RMSE_Tout_v3, MAE_Tout_v3);

%% ============================================================
% VARIANT 4: RE-TRENING HVER 12. TIME (VINDU = 12 TIMER), DAGLIG RE-INIT
% =============================================================
fprintf('\n=== VARIANT 4: Re-trening hver 12. time, daglig re-initialisering ===\n');

Tout_hat_v4 = nan(nValid + 1, 1);

for dIdx = 1:numel(uniqueValDays)
    thisDay = uniqueValDays(dIdx);
    dayMask = find(validDayIDs == thisDay);
    kStart  = dayMask(1);

    % Daglig re-initialisering (én gang per dag)
    Tout_hat_v4(kStart) = validTbl.Tout_k(kStart);

    % Innad i døgnet: to 12-timers re-treningsblokker (ingen re-init mellom dem)
    halfDayBlocks = {dayMask(1 : stepsHalfDay), ...
                     dayMask(stepsHalfDay+1 : end)};

    for b = 1:2
        blockIdx = halfDayBlocks{b};
        if isempty(blockIdx), continue; end

        globalStartTime = validTbl.Time_h_global(blockIdx(1));
        trainEndTime    = globalStartTime;
        trainStartTime  = trainEndTime - 12;

        trainMask_v4 = dataRows.Time_h_global >= trainStartTime & ...
                       dataRows.Time_h_global <  trainEndTime;
        trainTbl_v4  = dataRows(trainMask_v4, :);

        if height(trainTbl_v4) < 10
            c4 = c1;
        else
            mdl_v4_win = train_tout_model(trainTbl_v4, predictorVars, targetNameTout);
            c4 = mdl_v4_win.fitlm.Coefficients.Estimate;
        end

        % Ingen re-initialisering mellom blokkene — kjed videre
        for k = blockIdx'
            Tout_hat_v4(k+1) = c4(1) + c4(2)*Tout_hat_v4(k) ...
                              + c4(3)*PVP_k_vec(k) + c4(4)*dPVP_k_vec(k);
        end
    end
end

Tin_hat_v4    = Tout_hat_v4 + PVP_series ./ (cf * flow_m3s);
DeltaT_hat_v4 = Tout_hat_v4 - Tin_hat_v4;

RMSE_Tout_v4 = sqrt(mean((Tout_true(2:end) - Tout_hat_v4(2:end)).^2, 'omitnan'));
MAE_Tout_v4  = mean(abs(Tout_true(2:end) - Tout_hat_v4(2:end)), 'omitnan');

fprintf('  RMSE Tout: %.4f C  |  MAE Tout: %.4f C\n', RMSE_Tout_v4, MAE_Tout_v4);

%% ------------------------------------------------------------
% SAMMENLIGNING (baseline = V3, re-trening hver dag, 24t vindu)
% -------------------------------------------------------------
disp(' ')
disp('============================================================')
disp('SAMMENLIGNING AV VARIANTER (baseline = V3)')
disp('============================================================')
fprintf('%-32s  %8s  %10s  %8s  %10s\n', ...
    'Variant', 'RMSE [C]', 'Forb.RMSE', 'MAE [C]', 'Forb.MAE');
fprintf('%s\n', repmat('-', 1, 76));
RMSE_all = [RMSE_Tout_v1, RMSE_Tout_v2, RMSE_Tout_v3, RMSE_Tout_v4];
MAE_all  = [MAE_Tout_v1,  MAE_Tout_v2,  MAE_Tout_v3,  MAE_Tout_v4];
labels   = {'V1: re-trening 7d (vindu 7d)', ...
            'V2: daglig re-trening (vindu 7d)', ...
            'V3: re-trening 1d (vindu 24t)', ...
            'V4: re-trening 12t (vindu 12t)'};
baselineIdx = 3;
for v = 1:4
    forb_rmse = 100 * (1 - RMSE_all(v)/RMSE_all(baselineIdx));
    forb_mae  = 100 * (1 - MAE_all(v)/MAE_all(baselineIdx));
    fprintf('%-32s  %8.4f  %+9.1f %%  %8.4f  %+9.1f %%\n', ...
        labels{v}, RMSE_all(v), forb_rmse, MAE_all(v), forb_mae);
end
fprintf('  (Forb. = forbedring relativt V3. Positivt tall = bedre enn V3.)\n');

%% ------------------------------------------------------------
% LAGRE RESULTATER
% -------------------------------------------------------------
time_days = time_h / 24;

resultsTbl = table(time_h, time_days, PVP_series, ...
    Tout_true, Tout_hat_v1, Tout_hat_v2, Tout_hat_v3, Tout_hat_v4, ...
    Tin_true, Tin_hat_v1, Tin_hat_v2, Tin_hat_v3, Tin_hat_v4, ...
    DeltaT_true, DeltaT_hat_v1, DeltaT_hat_v2, DeltaT_hat_v3, DeltaT_hat_v4, ...
    'VariableNames', { ...
    'time_h','time_days','PVP_W', ...
    'Tout_true_C','Tout_hat_v1_C','Tout_hat_v2_C','Tout_hat_v3_C','Tout_hat_v4_C', ...
    'Tin_true_C','Tin_hat_v1_C','Tin_hat_v2_C','Tin_hat_v3_C','Tin_hat_v4_C', ...
    'DeltaT_true_C','DeltaT_hat_v1_C','DeltaT_hat_v2_C', ...
    'DeltaT_hat_v3_C','DeltaT_hat_v4_C'});

writetable(resultsTbl, fullfile(runRoot, 'validation_results_fyringssesong.csv'));

save(fullfile(runRoot, 'validation_results_fyringssesong.mat'), ...
    'resultsTbl', ...
    'RMSE_Tout_v1', 'MAE_Tout_v1', ...
    'RMSE_Tout_v2', 'MAE_Tout_v2', ...
    'RMSE_Tout_v3', 'MAE_Tout_v3', ...
    'RMSE_Tout_v4', 'MAE_Tout_v4', ...
    'mdl_init');

fprintf('\nFerdig. Resultater lagret i: %s\n', runRoot);

%% ============================================================
% ANALYSE OG FIGURER
%
% Samme figursett som det opprinnelige analyseskriptet, men uten
% kulde/varme-markering (mark_anomaly_periods er fjernet). Helgene
% skyggelegges fortsatt grått via mark_weekends.
%% ============================================================

% Kartlegg til de variabelnavnene figurkoden bruker
PVP_W   = PVP_series;
Tout_v1 = Tout_hat_v1;
Tout_v2 = Tout_hat_v2;
Tout_v3 = Tout_hat_v3;
Tout_v4 = Tout_hat_v4;

%% ------------------------------------------------------------
% KUTT DATASETTET TIL VALGT ANTALL DAGER
% -------------------------------------------------------------
if isfinite(daysToAnalyse)
    tStart = min(time_days);
    tEnd   = tStart + daysToAnalyse;

    idx = time_days >= tStart & time_days < tEnd;

    time_h    = time_h(idx);
    time_days = time_days(idx);
    PVP_W     = PVP_W(idx);

    Tout_true = Tout_true(idx);
    Tout_v1   = Tout_v1(idx);
    Tout_v2   = Tout_v2(idx);
    Tout_v3   = Tout_v3(idx);
    Tout_v4   = Tout_v4(idx);
end

nDaysTotal = ceil(max(time_days));
firstDay   = floor(min(time_days)) + 1;

% Beregn RMSE og MAE på nytt for valgt analyseperiode
e1 = Tout_true - Tout_v1;
e2 = Tout_true - Tout_v2;
e3 = Tout_true - Tout_v3;
e4 = Tout_true - Tout_v4;

RMSE = [sqrt(mean(e1.^2, 'omitnan')), ...
        sqrt(mean(e2.^2, 'omitnan')), ...
        sqrt(mean(e3.^2, 'omitnan')), ...
        sqrt(mean(e4.^2, 'omitnan'))];

MAE  = [mean(abs(e1), 'omitnan'), ...
        mean(abs(e2), 'omitnan'), ...
        mean(abs(e3), 'omitnan'), ...
        mean(abs(e4), 'omitnan')];

% Fullstendige navn til tabeller / Command Window
varNames = {'V1: 7-dagers regresjon med retrening hver 7. dag', ...
            'V2: 7-dagers glidende regresjon', ...
            'V3: 24-timers regresjon', ...
            'V4: 12-timers regresjon'};

% Kortere navn til figurer / legend
varLabels = {'V1: 7d reg. + retrening hver 7. dag', ...
             'V2: 7d glidende reg.', ...
             'V3: 24t reg.', ...
             'V4: 12t reg.'};

varColors = {[0.85 0.1 0.1], [0 0.6 0], [0.6 0 0.6], [0.85 0.5 0]};

dayRangeStr = sprintf('dag %d–%d', firstDay, nDaysTotal);

fprintf('\nAnalyseperiode: %s | start: %s\n', ...
    dayRangeStr, datestr(simStartDate, 'yyyy-mm-dd'));
fprintf('--- Metrics for valgt analyseperiode ---\n');
for v = 1:4
    fprintf('  %-55s RMSE = %.4f C  |  MAE = %.4f C\n', ...
        varNames{v}, RMSE(v), MAE(v));
end

%% ============================================================
% FIGUR 1 — Tout (alle varianter)
% =============================================================
figure('Name','Fig1: Tout','Position',[40 60 1500 420]);

plot(time_days, Tout_true, 'b-', 'LineWidth', 1.5); hold on
plot(time_days, Tout_v1,   '-',  'Color', varColors{1}, 'LineWidth', 1.0)
plot(time_days, Tout_v2,   '--', 'Color', varColors{2}, 'LineWidth', 1.0)
plot(time_days, Tout_v3,   ':',  'Color', varColors{3}, 'LineWidth', 1.2)
plot(time_days, Tout_v4,   '-.', 'Color', varColors{4}, 'LineWidth', 1.0)

yl = [0 8];
ylim(yl)

mark_weekends(simStartDate, time_days, yl)

ylim(yl)
ylabel('T_{ut} [°C]')
xlabel('Tid [dager]')
grid on
title(sprintf('T_{ut}: simulert og predikert — %s', dayRangeStr))
legend([{'Simulert'}, varLabels], 'Location', 'best')
hold off

%% ============================================================
% FIGUR 2 — PVP-profil
% =============================================================
figure('Name','Fig2: PVP','Position',[40 60 1500 350]);

stairs(time_days, PVP_W / 1000, 'Color', [0.2 0.4 0.8], 'LineWidth', 0.8)
hold on
mark_weekends(simStartDate, time_days, ylim)

ylabel('PVP [kW]')
xlabel('Tid [dager]')
grid on
title(sprintf('Effektuttak (PVP) — analyse %s   (grå = helg)', dayRangeStr))
hold off

%% ============================================================
% FIGUR 3 — Absolutt feil per variant over tid
% =============================================================
err_v1 = abs(Tout_true - Tout_v1);
err_v2 = abs(Tout_true - Tout_v2);
err_v3 = abs(Tout_true - Tout_v3);
err_v4 = abs(Tout_true - Tout_v4);

fig3YLim = [0 1.2];

figure('Name','Fig3: Absolutt feil','Position',[40 60 1500 550]);

subplot(2,2,1)
plot(time_days, err_v1, 'Color', varColors{1}); hold on
ylim(fig3YLim)
mark_weekends(simStartDate, time_days, fig3YLim)
title(sprintf('%s — MAE = %.4f °C', varLabels{1}, MAE(1)))
ylabel('|feil| [°C]')
grid on
hold off

subplot(2,2,2)
plot(time_days, err_v2, 'Color', varColors{2}); hold on
ylim(fig3YLim)
mark_weekends(simStartDate, time_days, fig3YLim)
title(sprintf('%s — MAE = %.4f °C', varLabels{2}, MAE(2)))
ylabel('|feil| [°C]')
grid on
hold off

subplot(2,2,3)
plot(time_days, err_v3, 'Color', varColors{3}); hold on
ylim(fig3YLim)
mark_weekends(simStartDate, time_days, fig3YLim)
title(sprintf('%s — MAE = %.4f °C', varLabels{3}, MAE(3)))
ylabel('|feil| [°C]')
xlabel('Tid [dager]')
grid on
hold off

subplot(2,2,4)
plot(time_days, err_v4, 'Color', varColors{4}); hold on
ylim(fig3YLim)
mark_weekends(simStartDate, time_days, fig3YLim)
title(sprintf('%s — MAE = %.4f °C', varLabels{4}, MAE(4)))
ylabel('|feil| [°C]')
xlabel('Tid [dager]')
grid on
hold off

sgtitle('Absolutt prediksjonsfeil |T_{ut,sann} − T_{ut,hat}|   (grå = helg)')

%% ============================================================
% FIGUR 4 — Rullende RMSE
% =============================================================
windowSize = 672;   % 7 dager × 96 tidssteg/dag

roll_v1 = movmean(err_v1.^2, windowSize).^0.5;
roll_v2 = movmean(err_v2.^2, windowSize).^0.5;
roll_v3 = movmean(err_v3.^2, windowSize).^0.5;
roll_v4 = movmean(err_v4.^2, windowSize).^0.5;

figure('Name','Fig4: Rullende RMSE','Position',[40 60 1500 420]);

plot(time_days, roll_v1, '-',  'Color', varColors{1}, 'LineWidth', 1.2); hold on
plot(time_days, roll_v2, '--', 'Color', varColors{2}, 'LineWidth', 1.2)
plot(time_days, roll_v3, ':',  'Color', varColors{3}, 'LineWidth', 1.5)
plot(time_days, roll_v4, '-.', 'Color', varColors{4}, 'LineWidth', 1.2)

mark_weekends(simStartDate, time_days, ylim)

ylabel('Rullende RMSE [°C]')
xlabel('Tid [dager]')
grid on
title(sprintf('Rullende RMSE, vindu = %d tidssteg = 7 dager   (grå = helg)', windowSize))
legend(varLabels, 'Location', 'best')
hold off

%% ============================================================
% FIGUR 5 — Feil-histogram per variant
% =============================================================
figure('Name','Fig5: Feil-histogram','Position',[40 60 1200 600]);

all_err = {Tout_true - Tout_v1, ...
           Tout_true - Tout_v2, ...
           Tout_true - Tout_v3, ...
           Tout_true - Tout_v4};

fig5XLim = [-1 1];
fig5YLim = [0 1500];
fig5Bins = 80;

binEdges = linspace(fig5XLim(1), fig5XLim(2), fig5Bins + 1);

for v = 1:4
    subplot(2,2,v)

    e = all_err{v};
    e = e(~isnan(e));

    histogram(e, ...
        'BinEdges', binEdges, ...
        'FaceColor', varColors{v}, ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.75)

    hold on

    xline(0, 'k--', 'LineWidth', 1.2)

    biasVal = mean(e, 'omitnan');

    if biasVal >= fig5XLim(1) && biasVal <= fig5XLim(2)
        xline(biasVal, 'r-', sprintf('Bias=%.3f', biasVal), ...
            'LineWidth', 1.2, ...
            'LabelOrientation', 'aligned', ...
            'LabelVerticalAlignment', 'top')
    end

    xlim(fig5XLim)
    ylim(fig5YLim)

    xlabel('Feil T_{ut} [°C]')
    ylabel('Antall')
    title(varLabels{v})
    grid on
    hold off
end

sgtitle('Feilfordeling T_{ut,sann} − T_{ut,hat}')

%% ============================================================
% FIGUR 6 — Scatter: predikert vs. simulert Tout
% =============================================================
figure('Name','Fig6: Scatter predikert vs simulert','Position',[40 60 1200 600]);

lims = [min(Tout_true)-0.2, max(Tout_true)+0.2];
Tpred = [Tout_v1, Tout_v2, Tout_v3, Tout_v4];

for v = 1:4
    subplot(2,2,v)

    scatter(Tout_true, Tpred(:,v), 2, varColors{v}, ...
        'filled', 'MarkerFaceAlpha', 0.3)

    hold on
    plot(lims, lims, 'k--', 'LineWidth', 1.2)

    xlabel('Simulert T_{ut} [°C]')
    ylabel('Predikert T_{ut} [°C]')
    title(sprintf('%s\nRMSE = %.4f °C', varLabels{v}, RMSE(v)))

    xlim(lims)
    ylim(lims)
    axis square
    grid on
    hold off
end

sgtitle('Scatter: predikert vs. simulert T_{ut}')

%% ============================================================
% FIGUR 7 — Tout: simulert vs V3/V4 (fokusert sammenligning)
% =============================================================
figure('Name','Fig7: Tout V3/V4','Position',[40 60 1500 450]);

plot(time_days, Tout_true, 'b-', 'LineWidth', 1.4); hold on
plot(time_days, Tout_v3,   ':',  'Color', varColors{3}, 'LineWidth', 1.3)
plot(time_days, Tout_v4,   '-.', 'Color', varColors{4}, 'LineWidth', 1.3)

ylims_cur = [0 8];
ylim(ylims_cur)

mark_weekends(simStartDate, time_days, ylims_cur)

ylabel('T_{ut} [°C]')
xlabel('Tid [dager]')
grid on
title('T_{ut}: simulert vs. V3/V4   (grå = helg)')
legend('Simulert', varLabels{3}, varLabels{4}, 'Location', 'best')
hold off

%% ============================================================
% FIGUR 8 — RMSE per dag
% =============================================================
stepsPerDay = 96;

nValidSamples = numel(Tout_true);
nDaysValid    = floor(nValidSamples / stepsPerDay);
barDays       = firstDay:(firstDay + nDaysValid - 1);

rmse_day = nan(nDaysValid, 4);
preds    = {Tout_v1, Tout_v2, Tout_v3, Tout_v4};

for di = 1:nDaysValid
    i0 = (di-1)*stepsPerDay + 1;
    i1 = min(i0 + stepsPerDay - 1, nValidSamples);

    for v = 1:4
        e = Tout_true(i0:i1) - preds{v}(i0:i1);
        rmse_day(di,v) = sqrt(mean(e.^2, 'omitnan'));
    end
end

fig8Width = min(max(1500, 8 * nDaysValid), 2400);
figure('Name','Fig8: RMSE per dag','Position',[40 60 fig8Width 500]);

fig8YLim = [0 5];

bar(barDays, rmse_day, 'grouped'); hold on
colormap(lines(4))

ylim(fig8YLim)

xlabel('Dag'); ylabel('RMSE [°C]'); grid on
title(sprintf('RMSE per dag — alle 4 varianter (%d dager)   (grå = helg)', nDaysValid))
legend(varLabels, 'Location', 'best')

mark_weekends(simStartDate, barDays, fig8YLim)

hold off

%% ============================================================
% FIGUR 9 — Tout og PVP koblet
% =============================================================
figure('Name','Fig9: Tout og PVP koblet','Position',[40 60 1500 800]);

tl = tiledlayout(2, 1, ...
    'TileSpacing', 'loose', ...
    'Padding', 'compact');

% --- Toppfelt: T_ut ----------------------------------------------
ax1 = nexttile;

plot(ax1, time_days, Tout_true, 'b-',  'LineWidth', 1.5); hold(ax1, 'on')
plot(ax1, time_days, Tout_v1,   '-',   'Color', varColors{1}, 'LineWidth', 1.0)
plot(ax1, time_days, Tout_v2,   '--',  'Color', varColors{2}, 'LineWidth', 1.0)
plot(ax1, time_days, Tout_v3,   ':',   'Color', varColors{3}, 'LineWidth', 1.2)
plot(ax1, time_days, Tout_v4,   '-.',  'Color', varColors{4}, 'LineWidth', 1.0)

ylim(ax1, [0 8])
mark_weekends(simStartDate, time_days, ylim(ax1))
ylim(ax1, [0 8])

ylabel(ax1, 'T_{ut} [°C]')
grid(ax1, 'on')
title(ax1, 'Utløpstemperatur (T_{ut}) — simulert og predikert')
legend(ax1, [{'Simulert'}, varLabels], 'Location', 'best')
hold(ax1, 'off')

% --- Bunnfelt: PVP -----------------------------------------------
ax2 = nexttile;

stairs(ax2, time_days, PVP_W / 1000, ...
    'Color', [0.2 0.4 0.8], ...
    'LineWidth', 0.8)

hold(ax2, 'on')

mark_weekends(simStartDate, time_days, ylim(ax2))

ylabel(ax2, 'PVP [kW]')
grid(ax2, 'on')
title(ax2, 'Effektuttak (PVP) — pådrag på borehullet')
hold(ax2, 'off')

xlabel(tl, 'Tid [dager]')
title(tl, sprintf('T_{ut} og PVP, koblet visning, %s   (grå = helg)', dayRangeStr))

linkaxes([ax1 ax2], 'x')
xlim(ax1, [min(time_days) max(time_days)])

%% ------------------------------------------------------------
% SAMMENDRAGSTABELL I COMMAND WINDOW
% -------------------------------------------------------------
% Sammenligningen er relativ til V2 (7-dagers glidende regresjon)
baseIdx = 2;

fprintf('\n');
fprintf('Sammenligning relativ til %s\n', varNames{baseIdx});
fprintf('%-60s  %8s  %10s  %8s  %10s\n', ...
    'Variant', 'RMSE [C]', 'Forb.RMSE', 'MAE [C]', 'Forb.MAE');
fprintf('%s\n', repmat('-', 1, 115));

for v = 1:4
    forb_rmse = 100 * (1 - RMSE(v)/RMSE(baseIdx));
    forb_mae  = 100 * (1 - MAE(v)/MAE(baseIdx));

    fprintf('%-60s  %8.4f  %+9.1f %%  %8.4f  %+9.1f %%\n', ...
        varNames{v}, RMSE(v), forb_rmse, MAE(v), forb_mae);
end

fprintf('\n');

%% ============================================================
% LOKALE HJELPEFUNKSJONER
%% ============================================================
function mdl = train_tout_model(trainTbl, predictorVars, targetVar)
% TRAIN_TOUT_MODEL
%   Tilpasser en lineær regresjonsmodell
%     T_ut(k+1) ~ b0 + b1*Tout_k + b2*PVP_k + b3*dPVP_k
%   via fitlm. Returnerer en struct med formelen, valgte prediktorer
%   og selve LinearModel-objektet.
    rhs     = strjoin(predictorVars, ' + ');
    formula = sprintf('%s ~ %s', targetVar, rhs);
    mdl = struct();
    mdl.selectedVars = predictorVars;
    mdl.formula      = formula;
    mdl.fitlm        = fitlm(trainTbl, formula);
end

%% ============================================================
% LOKAL HJELPEFUNKSJON — marker helger med grå skygge
%% ============================================================
function mark_weekends(startDate, timeOrDays, ylims_in)

    if nargin < 3 || isempty(ylims_in)
        ylims_cur = ylim;
    else
        ylims_cur = ylims_in;
    end

    if isempty(timeOrDays)
        return;
    end

    xMin = min(timeOrDays);
    xMax = max(timeOrDays);

    nDays = ceil(xMax);

    if nDays < 1
        return;
    end

    dates = startDate + days(0:nDays-1);
    isWE  = isweekend(dates);

    d = 1;

    while d <= nDays
        if isWE(d)
            wkStartDay = d;

            while d <= nDays && isWE(d)
                d = d + 1;
            end

            wkEndDay = d - 1;

            x0 = max(wkStartDay - 1, xMin);
            x1 = min(wkEndDay,       xMax);

            if x1 > x0
                patch([x0 x1 x1 x0], ...
                      [ylims_cur(1) ylims_cur(1) ylims_cur(2) ylims_cur(2)], ...
                      [0.55 0.55 0.55], ...
                      'FaceAlpha', 0.18, ...
                      'EdgeColor', 'none', ...
                      'HandleVisibility', 'off');
            end
        else
            d = d + 1;
        end
    end
end
