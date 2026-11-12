# ELRD-Backend als Container. Bauen im Ordner backend/:
#   docker build -t elrd-backend .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/ELRD.Backend/ELRD.Backend.csproj src/ELRD.Backend/
RUN dotnet restore src/ELRD.Backend/ELRD.Backend.csproj
COPY src/ src/
RUN dotnet publish src/ELRD.Backend/ELRD.Backend.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
# Daten (store.json) liegen in einem Volume; der Container läuft ohne root.
ENV ASPNETCORE_HTTP_PORTS=8080 \
    Elrd__Storage__DataDirectory=/data
RUN mkdir -p /data && chown app:app /data
VOLUME /data
USER app
EXPOSE 8080
ENTRYPOINT ["dotnet", "ELRD.Backend.dll"]
