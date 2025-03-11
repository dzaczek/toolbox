package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

const domainsFile = "domains.txt"
const maxColumnWidth = 20

// HistoryEntry represents a single change in a record set
type HistoryEntry struct {
	Timestamp time.Time `json:"timestamp"`
	Values    []string  `json:"values"` // Store the full set of records
}

// RecordHistory stores the history of changes for a record type
type RecordHistory map[string][]HistoryEntry // record type -> history of sets

func truncateString(s string, maxLen int) string {
	if len(s) > maxLen {
		return s[:maxLen-3] + "..."
	}
	return s
}

func main() {
	domains, err := readDomains(domainsFile)
	if err != nil {
		fmt.Printf("Error reading domains: %v\n", err)
		return
	}

	history := make(map[string]RecordHistory)
	for _, domain := range domains {
		history[domain], err = loadHistory(domain)
		if err != nil {
			fmt.Printf("Error loading history for %s: %v\n", domain, err)
			history[domain] = make(RecordHistory)
		}
		if history[domain] == nil {
			history[domain] = make(RecordHistory)
			history[domain]["NS"] = []HistoryEntry{}
			history[domain]["IP"] = []HistoryEntry{}
			history[domain]["PTR"] = []HistoryEntry{}
			history[domain]["A"] = []HistoryEntry{}
			history[domain]["MX"] = []HistoryEntry{}
			history[domain]["TXT"] = []HistoryEntry{}
		}
	}

	app := tview.NewApplication()
	table := tview.NewTable().
		SetBorders(true).
		SetSelectable(true, true)

	type blinkState struct {
		Row, Col    int
		NormalColor tcell.Color
		BlinkRate   time.Duration
	}
	var blinkingCells []blinkState

	updateTable := func() {
		table.Clear()
		nsData, ipData, ptrData, aData, mxData, txtData, maxCounts := gatherDnsData(domains)
		blinkingCells = nil

		// Header row
		table.SetCell(0, 0, tview.NewTableCell("INFORMATION").SetTextColor(tcell.ColorYellow))
		for col, domain := range domains {
			table.SetCell(0, col+1, tview.NewTableCell(truncateString(domain, maxColumnWidth)).SetTextColor(tcell.ColorYellow))
		}

		// NS Server rows (green)
		rowOffset := 0
		for i := 0; i < maxCounts["NS"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("NS Server #%d", i+1)).SetTextColor(tcell.ColorGreen))
			for col, domain := range domains {
				value := "N/A"
				if i < len(nsData[domain]) {
					value = nsData[domain][i]
				}
				updateHistory(history, domain, "NS", nsData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorGreen)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["NS"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorGreen, getBlinkRate(history[domain]["NS"])})
				}
			}
		}

		// IP Address rows (blue)
		rowOffset += maxCounts["NS"]
		for i := 0; i < maxCounts["IP"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("IP Address #%d", i+1)).SetTextColor(tcell.ColorBlue))
			for col, domain := range domains {
				value := "N/A"
				if i < len(ipData[domain]) {
					value = ipData[domain][i]
				}
				updateHistory(history, domain, "IP", ipData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorBlue)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["IP"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorBlue, getBlinkRate(history[domain]["IP"])})
				}
			}
		}

		// PTR Record rows (purple)
		rowOffset += maxCounts["IP"]
		for i := 0; i < maxCounts["PTR"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("PTR Record #%d", i+1)).SetTextColor(tcell.ColorPurple))
			for col, domain := range domains {
				value := "N/A"
				if i < len(ptrData[domain]) {
					value = ptrData[domain][i]
				}
				updateHistory(history, domain, "PTR", ptrData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorPurple)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["PTR"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorPurple, getBlinkRate(history[domain]["PTR"])})
				}
			}
		}

		// A Record rows (red)
		rowOffset += maxCounts["PTR"]
		for i := 0; i < maxCounts["A"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("A Record #%d", i+1)).SetTextColor(tcell.ColorRed))
			for col, domain := range domains {
				value := "N/A"
				if i < len(aData[domain]) {
					value = aData[domain][i]
				}
				updateHistory(history, domain, "A", aData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorRed)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["A"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorRed, getBlinkRate(history[domain]["A"])})
				}
			}
		}

		// MX Record rows (aqua)
		rowOffset += maxCounts["A"]
		for i := 0; i < maxCounts["MX"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("MX Record #%d", i+1)).SetTextColor(tcell.ColorAqua))
			for col, domain := range domains {
				value := "N/A"
				if i < len(mxData[domain]) {
					value = mxData[domain][i]
				}
				updateHistory(history, domain, "MX", mxData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorAqua)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["MX"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorAqua, getBlinkRate(history[domain]["MX"])})
				}
			}
		}

		// TXT Record rows (white)
		rowOffset += maxCounts["MX"]
		for i := 0; i < maxCounts["TXT"]; i++ {
			row := rowOffset + i + 1
			table.SetCell(row, 0, tview.NewTableCell(fmt.Sprintf("TXT Record #%d", i+1)).SetTextColor(tcell.ColorWhite))
			for col, domain := range domains {
				value := "N/A"
				if i < len(txtData[domain]) {
					value = txtData[domain][i]
				}
				updateHistory(history, domain, "TXT", txtData[domain])
				cell := tview.NewTableCell(truncateString(value, maxColumnWidth)).SetTextColor(tcell.ColorWhite)
				table.SetCell(row, col+1, cell)
				if shouldBlink(history[domain]["TXT"]) {
					blinkingCells = append(blinkingCells, blinkState{row, col+1, tcell.ColorWhite, getBlinkRate(history[domain]["TXT"])})
				}
			}
		}

		// Save history
		for domain := range history {
			if err := saveHistory(domain, history[domain]); err != nil {
				fmt.Printf("Error saving history for %s: %v\n", domain, err)
			}
		}
	}

	// Blinking goroutine
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		blinkOn := false
		for range ticker.C {
			blinkOn = !blinkOn
			for _, state := range blinkingCells {
				cell := table.GetCell(state.Row, state.Col)
				if blinkOn && (time.Now().Sub(time.Now().Truncate(time.Second)) < state.BlinkRate || state.BlinkRate == 500*time.Millisecond) {
					cell.SetTextColor(tcell.ColorWhite)
				} else {
					cell.SetTextColor(state.NormalColor)
				}
			}
			app.Draw()
		}
	}()

	// Handle cell selection
	table.SetSelectedFunc(func(row, col int) {
		if row == 0 || col == 0 {
			return
		}
		domain := domains[col-1]
		var recordType string
		var index int
		maxCounts := map[string]int{
			"NS":  table.GetRowCount() / 6,
			"IP":  table.GetRowCount() / 6,
			"PTR": table.GetRowCount() / 6,
			"A":   table.GetRowCount() / 6,
			"MX":  table.GetRowCount() / 6,
			"TXT": table.GetRowCount() / 6,
		}
		switch {
		case row <= maxCounts["NS"]:
			recordType = "NS"
			index = row - 1
		case row <= maxCounts["NS"]+maxCounts["IP"]:
			recordType = "IP"
			index = row - maxCounts["NS"] - 1
		case row <= maxCounts["NS"]+maxCounts["IP"]+maxCounts["PTR"]:
			recordType = "PTR"
			index = row - maxCounts["NS"] - maxCounts["IP"] - 1
		case row <= maxCounts["NS"]+maxCounts["IP"]+maxCounts["PTR"]+maxCounts["A"]:
			recordType = "A"
			index = row - maxCounts["NS"] - maxCounts["IP"] - maxCounts["PTR"] - 1
		case row <= maxCounts["NS"]+maxCounts["IP"]+maxCounts["PTR"]+maxCounts["A"]+maxCounts["MX"]:
			recordType = "MX"
			index = row - maxCounts["NS"] - maxCounts["IP"] - maxCounts["PTR"] - maxCounts["A"] - 1
		default:
			recordType = "TXT"
			index = row - maxCounts["NS"] - maxCounts["IP"] - maxCounts["PTR"] - maxCounts["A"] - maxCounts["MX"] - 1
		}

		modal := tview.NewModal()
		historyKey := fmt.Sprintf("%s #%d", recordType, index+1)
		hist := history[domain][recordType]
		if len(hist) > 0 {
			var historyText strings.Builder
			historyText.WriteString(fmt.Sprintf("History for %s - %s:\n\n", domain, historyKey))
			for _, entry := range hist {
				historyText.WriteString(fmt.Sprintf("%s: %v\n", entry.Timestamp.Format(time.RFC1123), entry.Values))
			}
			modal.SetText(historyText.String())
		} else {
			modal.SetText(fmt.Sprintf("No history available for %s - %s", domain, historyKey))
		}
		modal.AddButtons([]string{"Close"}).SetDoneFunc(func(buttonIndex int, buttonLabel string) {
			app.SetRoot(table, true)
		})
		app.SetRoot(modal, false)
	})

	// Initial update
	updateTable()

	// Periodic updates
	go func() {
		for {
			time.Sleep(30 * time.Second)
			updateTable()
			app.Draw()
		}
	}()

	if err := app.SetRoot(table, true).Run(); err != nil {
		panic(err)
	}
}

// shouldBlink checks if a record set should blink
func shouldBlink(hist []HistoryEntry) bool {
	if len(hist) < 2 {
		return false
	}
	lastChange := hist[len(hist)-1].Timestamp
	oneHourAgo := time.Now().Add(-1 * time.Hour)
	oneDayAgo := time.Now().Add(-24 * time.Hour)
	changesInDay := 0
	for _, entry := range hist {
		if entry.Timestamp.After(oneDayAgo) {
			changesInDay++
		}
	}
	return lastChange.After(oneHourAgo) || changesInDay > 1
}

// getBlinkRate determines the blink rate
func getBlinkRate(hist []HistoryEntry) time.Duration {
	if len(hist) < 2 {
		return 0
	}
	lastChange := hist[len(hist)-1].Timestamp
	oneHourAgo := time.Now().Add(-1 * time.Hour)
	oneDayAgo := time.Now().Add(-24 * time.Hour)
	changesInDay := 0
	for _, entry := range hist {
		if entry.Timestamp.After(oneDayAgo) {
			changesInDay++
		}
	}
	if lastChange.After(oneHourAgo) {
		return 1 * time.Second
	}
	if changesInDay > 1 {
		return 500 * time.Millisecond
	}
	return 0
}

// readDomains reads domains from the specified file
func readDomains(filename string) ([]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var domains []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		domain := strings.TrimSpace(scanner.Text())
		if domain != "" {
			domains = append(domains, domain)
		}
	}
	return domains, scanner.Err()
}

// gatherDnsData fetches all DNS record types
func gatherDnsData(domains []string) (nsData, ipData, ptrData, aData, mxData, txtData map[string][]string, maxCounts map[string]int) {
	nsData = make(map[string][]string)
	ipData = make(map[string][]string)
	ptrData = make(map[string][]string)
	aData = make(map[string][]string)
	mxData = make(map[string][]string)
	txtData = make(map[string][]string)
	maxCounts = make(map[string]int)

	for _, domain := range domains {
		nsRecords := digNs(domain)
		nsData[domain] = nsRecords
		if len(nsRecords) > maxCounts["NS"] {
			maxCounts["NS"] = len(nsRecords)
		}
		ipData[domain] = make([]string, len(nsRecords))
		ptrData[domain] = make([]string, len(nsRecords))
		for i, ns := range nsRecords {
			ips := digA(ns)
			ip := "N/A"
			if len(ips) > 0 {
				ip = ips[0]
			}
			ipData[domain][i] = ip
			if ip != "N/A" {
				ptr := digPtr(ip)
				ptrData[domain][i] = ptr
			} else {
				ptrData[domain][i] = "N/A"
			}
		}
		if len(ipData[domain]) > maxCounts["IP"] {
			maxCounts["IP"] = len(ipData[domain])
		}
		if len(ptrData[domain]) > maxCounts["PTR"] {
			maxCounts["PTR"] = len(ptrData[domain])
		}

		aRecords := digA(domain)
		aData[domain] = aRecords
		if len(aRecords) > maxCounts["A"] {
			maxCounts["A"] = len(aRecords)
		}

		mxRecords := digMx(domain)
		mxData[domain] = mxRecords
		if len(mxRecords) > maxCounts["MX"] {
			maxCounts["MX"] = len(mxRecords)
		}

		txtRecords := digTxt(domain)
		txtData[domain] = txtRecords
		if len(txtRecords) > maxCounts["TXT"] {
			maxCounts["TXT"] = len(txtRecords)
		}
	}
	return
}

// updateHistory adds a new entry if the record set changes (ignoring order)
func updateHistory(history map[string]RecordHistory, domain, recordType string, values []string) {
	hist := history[domain][recordType]
	if len(hist) == 0 {
		history[domain][recordType] = append(hist, HistoryEntry{
			Timestamp: time.Now(),
			Values:    values,
		})
		return
	}

	// Sort both current and last values to ignore order
	sort.Strings(values)
	lastValues := hist[len(hist)-1].Values
	sort.Strings(lastValues)

	// Compare sets
	if !equalSlices(values, lastValues) {
		history[domain][recordType] = append(hist, HistoryEntry{
			Timestamp: time.Now(),
			Values:    values,
		})
	}
}

// equalSlices compares two sorted string slices
func equalSlices(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// loadHistory reads history from a file
func loadHistory(domain string) (RecordHistory, error) {
	filename := fmt.Sprintf("%s_history.json", domain)
	data, err := os.ReadFile(filename)
	if os.IsNotExist(err) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	var hist RecordHistory
	if err := json.Unmarshal(data, &hist); err != nil {
		return nil, err
	}
	return hist, nil
}

// saveHistory writes history to a file
func saveHistory(domain string, hist RecordHistory) error {
	filename := fmt.Sprintf("%s_history.json", domain)
	data, err := json.MarshalIndent(hist, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filename, data, 0644)
}

// digNs runs "dig +short NS domain"
func digNs(domain string) []string {
	return runDig("+short NS " + domain)
}

// digA runs "dig +short A domain/ns"
func digA(domain string) []string {
	return runDig("+short A " + domain)
}

// digMx runs "dig +short MX domain"
func digMx(domain string) []string {
	return runDig("+short MX " + domain)
}

// digTxt runs "dig +short TXT domain"
func digTxt(domain string) []string {
	return runDig("+short TXT " + domain)
}

// digPtr runs "dig +short -x ip"
func digPtr(ip string) string {
	ptrs := runDig("+short -x " + ip)
	if len(ptrs) > 0 {
		return strings.TrimSuffix(ptrs[0], ".")
	}
	return "No PTR"
}

// runDig executes a dig command
func runDig(args string) []string {
	cmd := exec.Command("dig", strings.Fields(args)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return []string{}
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	return lines
}
