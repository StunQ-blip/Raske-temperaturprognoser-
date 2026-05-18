# Raske temperaturprognoser for energibrønner

Dette repositoryet inneholder MATLAB-kode og datagrunnlag brukt i bacheloroppgaven *Raske temperaturprognoser for energibrønner med regresjonsanalyse*.

## Innhold

- `regresjon_fra_lagret_data.m`  
  MATLAB-kode for trening og evaluering av regresjonsmodell basert på lagrede simuleringsdata.

- `dataset_for_regression.xlsx`  
  Datasett eksportert fra FDM-simuleringen og brukt som treningsgrunnlag for regresjonsmodellen.

## Bruk

1. Last ned repositoryet.
2. Åpne MATLAB.
3. Sørg for at `dataset_for_regression.xlsx` ligger i samme mappe som `regresjon_fra_lagret_data.m`.
4. Kjør filen:

```matlab
regresjon_fra_lagret_data


Koden er utviklet som del av bacheloroppgaven ved studieprogrammet Energi og miljø i bygg, OsloMet, 2026.

Forfattere
Mateusz Bartosz Rynski
Per Anders Olsen
